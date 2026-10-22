use super::{source::Source, stream::Reader, BLOCK_SIZE, MAX_OPENING, MAX_QUEUED, MAX_SESSIONS};
use crate::api::media::{MediaError, MediaSession, MediaSessionRef, MediaSource};
use rand::RngCore;
use std::sync::mpsc;
use std::{
    collections::{HashMap, VecDeque},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::{oneshot, watch, OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::{CancellationToken, DropGuard};
use zeroize::Zeroizing;

type Result<T> = std::result::Result<T, MediaError>;
struct ReadOperation {
    offset: u64,
    length: usize,
    token: CancellationToken,
    reply: oneshot::Sender<Result<Vec<u8>>>,
}

pub struct Session {
    pub reference: MediaSessionRef,
    pub length: u64,
    pub content_type: String,
    root: CancellationToken,
    commands: mpsc::SyncSender<ReadOperation>,
    done: watch::Receiver<bool>,
}
impl Session {
    pub fn request_token(&self) -> CancellationToken {
        self.root.child_token()
    }
    pub async fn read(
        &self,
        offset: u64,
        length: usize,
        token: CancellationToken,
    ) -> Result<Vec<u8>> {
        if length == 0 || length > BLOCK_SIZE || offset >= self.length {
            return Err(MediaError::new("invalid_source"));
        }
        if token.is_cancelled() || self.root.is_cancelled() {
            return Err(MediaError::new("cancelled"));
        }
        // Each block owns a child; finishing one read must not cancel the
        // HTTP response token shared by subsequent blocks. Parent cancellation
        // still propagates to a blocked network request.
        let token = token.child_token();
        let _read_guard = token.clone().drop_guard();
        let (reply, result) = oneshot::channel();
        self.commands
            .try_send(ReadOperation {
                offset,
                length: length.min((self.length - offset) as usize),
                token: token.clone(),
                reply,
            })
            .map_err(|_| MediaError::new("busy"))?;
        tokio::select! {
            biased;
            _ = self.root.cancelled() => Err(MediaError::new("cancelled")),
            _ = token.cancelled() => Err(MediaError::new("cancelled")),
            result = result => result.unwrap_or_else(|_| Err(MediaError::new("unavailable"))),
        }
    }
    async fn drain(&self) {
        self.root.cancel();
        let mut done = self.done.clone();
        while !*done.borrow_and_update() {
            if done.changed().await.is_err() {
                break;
            }
        }
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.root.cancel();
    }
}

struct Opening {
    token: CancellationToken,
    done: watch::Receiver<bool>,
}
#[derive(Default)]
struct State {
    retired: bool,
    opening: HashMap<String, Opening>,
    sessions: HashMap<String, Arc<Session>>,
    pre_cancelled: VecDeque<String>,
}
pub struct MediaManager {
    generation: u64,
    runtime: PathBuf,
    state: Mutex<State>,
    slots: Arc<Semaphore>,
    opens: Arc<Semaphore>,
    test_origin: Option<String>,
}
impl MediaManager {
    pub fn new(runtime: PathBuf, generation: u64) -> Arc<Self> {
        Arc::new(Self {
            generation,
            runtime,
            state: Mutex::new(State::default()),
            slots: Arc::new(Semaphore::new(MAX_SESSIONS)),
            opens: Arc::new(Semaphore::new(MAX_OPENING)),
            test_origin: None,
        })
    }
    #[cfg(all(feature = "native-media-host-tests", not(target_os = "ios")))]
    pub fn with_test_transport(runtime: PathBuf, generation: u64, origin: String) -> Arc<Self> {
        let mut manager = Self::new(runtime, generation);
        Arc::get_mut(&mut manager).unwrap().test_origin = Some(origin);
        manager
    }
    pub fn counts(&self) -> (usize, usize) {
        let state = self.state.lock().unwrap();
        (state.sessions.len(), state.opening.len())
    }
    pub fn active_workers(&self) -> usize {
        MAX_SESSIONS - self.slots.available_permits()
    }
    pub fn lookup(&self, id: &str) -> Option<Arc<Session>> {
        self.state.lock().unwrap().sessions.get(id).cloned()
    }
    pub fn cancel(&self, id: &str) -> bool {
        if id.is_empty() || id.len() > 256 {
            return false;
        }
        let mut state = self.state.lock().unwrap();
        if let Some(open) = state.opening.get(id) {
            open.token.cancel();
            return true;
        }
        if !state.pre_cancelled.iter().any(|v| v == id) {
            if state.pre_cancelled.len() == 256 {
                state.pre_cancelled.pop_front();
            }
            state.pre_cancelled.push_back(id.into());
        }
        false
    }
    pub async fn create(
        self: &Arc<Self>,
        id: String,
        source: MediaSource,
        key: Option<Vec<u8>>,
    ) -> Result<MediaSession> {
        let key = key.map(Zeroizing::new);
        if id.is_empty() || id.len() > 256 || key.as_ref().is_some_and(|k| k.len() != 16) {
            return Err(MediaError::new("invalid_source"));
        }
        let token = CancellationToken::new();
        let (done_tx, done) = watch::channel(false);
        let (slot, open) = {
            let mut state = self.state.lock().unwrap();
            if state.retired {
                return Err(MediaError::new("unavailable"));
            }
            if let Some(index) = state.pre_cancelled.iter().position(|v| v == &id) {
                state.pre_cancelled.remove(index);
                return Err(MediaError::new("cancelled"));
            }
            if state.opening.contains_key(&id) {
                return Err(MediaError::new("busy"));
            }
            let slot = self
                .slots
                .clone()
                .try_acquire_owned()
                .map_err(|_| MediaError::new("busy"))?;
            let open = self
                .opens
                .clone()
                .try_acquire_owned()
                .map_err(|_| MediaError::new("busy"))?;
            state.opening.insert(
                id.clone(),
                Opening {
                    token: token.clone(),
                    done: done.clone(),
                },
            );
            (slot, open)
        };
        // Registered BEFORE length probe and BEFORE sp_stream_open. Dropping
        // the bridge future also cancels and removes its registration.
        let registration = Registration {
            manager: self.clone(),
            id,
            guard: Some(token.clone().drop_guard()),
        };
        let (commands, receiver) = mpsc::sync_channel(MAX_QUEUED);
        let (ready, opened) = oneshot::channel();
        let runtime = tokio::runtime::Handle::current();
        let runtime_dir = self.runtime.clone();
        let test_origin = self.test_origin.clone();
        let worker_token = token.clone();
        let spawn = std::thread::Builder::new()
            .name("fq-media".into())
            .spawn(move || {
                let _completion = Completion {
                    done: done_tx,
                    _slot: slot,
                };
                let result = Source::open(
                    source,
                    &runtime_dir,
                    worker_token.clone(),
                    runtime,
                    test_origin,
                )
                .and_then(|source| {
                    let metadata = (source.size, source.content_type.clone());
                    Reader::open(source, key).map(|reader| (reader, metadata))
                });
                drop(open);
                match result {
                    Ok((reader, metadata)) if !worker_token.is_cancelled() => {
                        if ready.send(Ok(metadata)).is_ok() {
                            run_worker(reader, receiver, &worker_token);
                        }
                    }
                    Ok(_) => {
                        let _ = ready.send(Err(MediaError::new("cancelled")));
                    }
                    Err(error) => {
                        let _ = ready.send(Err(error));
                    }
                }
            });
        if spawn.is_err() {
            return Err(MediaError::new("unavailable"));
        }
        let outcome = tokio::select! {
            biased;
            _ = token.cancelled() => Err(MediaError::new("cancelled")),
            result = tokio::time::timeout(Duration::from_secs(30), opened) => result.map_err(|_| MediaError::new("timeout")).and_then(|r| r.map_err(|_| MediaError::new("unavailable"))).and_then(|r| r),
        };
        let (length, content_type) = match outcome {
            Ok(value) => value,
            Err(error) => {
                token.cancel();
                let mut done = done.clone();
                while !*done.borrow_and_update() {
                    if done.changed().await.is_err() {
                        break;
                    }
                }
                return Err(error);
            }
        };
        let mut entropy = [0; 24];
        rand::rngs::OsRng
            .try_fill_bytes(&mut entropy)
            .map_err(|_| MediaError::new("unavailable"))?;
        let reference = MediaSessionRef {
            id: hex::encode(entropy),
            generation: self.generation,
        };
        let session = Arc::new(Session {
            reference: reference.clone(),
            length,
            content_type: content_type.clone(),
            root: token.clone(),
            commands,
            done,
        });
        {
            let mut state = self.state.lock().unwrap();
            if state.retired || token.is_cancelled() {
                return Err(MediaError::new("cancelled"));
            }
            state.sessions.insert(reference.id.clone(), session);
            // Publish and remove cancellation registration under the same lock.
            state.opening.remove(&registration.id);
        }
        registration.disarm();
        Ok(MediaSession {
            session: reference,
            playback_url: String::new(),
            content_length: length,
            content_type,
        })
    }
    pub async fn close(&self, reference: &MediaSessionRef) -> Result<()> {
        if reference.generation != self.generation {
            return Err(MediaError::new("unavailable"));
        }
        let session = self.state.lock().unwrap().sessions.remove(&reference.id);
        if let Some(session) = session {
            session.drain().await;
        }
        Ok(())
    }
    pub async fn shutdown(&self) {
        let (sessions, pending) = {
            let mut state = self.state.lock().unwrap();
            state.retired = true;
            for opening in state.opening.values() {
                opening.token.cancel();
            }
            (
                state.sessions.drain().map(|(_, s)| s).collect::<Vec<_>>(),
                state
                    .opening
                    .values()
                    .map(|o| o.done.clone())
                    .collect::<Vec<_>>(),
            )
        };
        for session in &sessions {
            session.root.cancel();
        }
        for session in sessions {
            session.drain().await;
        }
        for mut done in pending {
            while !*done.borrow_and_update() {
                if done.changed().await.is_err() {
                    break;
                }
            }
        }
        // Also drain workers whose create future was dropped before publication.
        let _all_slots = self.slots.acquire_many(MAX_SESSIONS as u32).await;
    }
}
impl Drop for MediaManager {
    fn drop(&mut self) {
        let state = self.state.get_mut().unwrap();
        for opening in state.opening.values() {
            opening.token.cancel();
        }
        for session in state.sessions.values() {
            session.root.cancel();
        }
    }
}
struct Registration {
    manager: Arc<MediaManager>,
    id: String,
    guard: Option<DropGuard>,
}
impl Registration {
    fn disarm(mut self) {
        if let Some(guard) = self.guard.take() {
            guard.disarm();
        }
    }
}
impl Drop for Registration {
    fn drop(&mut self) {
        if self.guard.is_some() {
            self.manager.state.lock().unwrap().opening.remove(&self.id);
        }
    }
}
struct Completion {
    done: watch::Sender<bool>,
    _slot: OwnedSemaphorePermit,
}
impl Drop for Completion {
    fn drop(&mut self) {
        let _ = self.done.send(true);
    }
}
fn run_worker(
    mut reader: Reader,
    receiver: mpsc::Receiver<ReadOperation>,
    root: &CancellationToken,
) {
    // The worker is bounded by a session slot. Tokio's blocking pool is not
    // occupied by parked sessions; Tokio only polls cancellable network futures.
    while !root.is_cancelled() {
        match receiver.recv_timeout(Duration::from_millis(50)) {
            Ok(op) => {
                if op.token.is_cancelled() || op.reply.is_closed() {
                    continue;
                }
                let result = reader.read_at(op.offset, op.length, op.token);
                let _ = op.reply.send(result);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
}
