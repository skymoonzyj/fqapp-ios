#![cfg(all(
    feature = "native-media-host-tests",
    any(target_os = "macos", target_os = "linux")
))]

mod common;

use common::{build_server, pool_json, TempDir};
use fqapi_core::{
    api::media::{MediaSessionRef, MediaSource},
    native_media::session::MediaManager,
};
use std::{sync::Arc, time::Duration};

#[tokio::test]
async fn head_full_partial_tail_and_unsatisfiable_ranges() {
    let dir = TempDir::new("media-range");
    let runtime = dir.path().join("runtime");
    std::fs::create_dir_all(&runtime).unwrap();
    let file = dir.path().join("sample.mp3");
    std::fs::write(&file, b"0123456789").unwrap();
    let manager = MediaManager::new(runtime, 1);
    let server = build_server(&dir, None, &[], &[], &pool_json(3)).await;
    let lb = fqapi_core::server::serve_with_media(server, 0, manager.clone())
        .await
        .unwrap();
    let session = manager
        .create(
            "ranges".into(),
            MediaSource::LocalFile {
                path: file.to_string_lossy().into(),
            },
            None,
        )
        .await
        .unwrap();
    let url = format!(
        "http://127.0.0.1:{}/_session/{}/media/{}",
        lb.port, lb.token, session.session.id
    );
    let client = reqwest::Client::new();
    let head = client.head(&url).send().await.unwrap();
    assert_eq!(head.status(), 200);
    assert_eq!(head.headers()["content-length"], "10");
    assert!(head.bytes().await.unwrap().is_empty());
    assert_eq!(
        client
            .get(&url)
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap(),
        b"0123456789"[..]
    );
    for (range, expected, cr) in [
        ("bytes=2-5", &b"2345"[..], "bytes 2-5/10"),
        ("bytes=-3", &b"789"[..], "bytes 7-9/10"),
    ] {
        let response = client
            .get(&url)
            .header("range", range)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 206);
        assert_eq!(response.headers()["content-range"], cr);
        assert_eq!(response.bytes().await.unwrap(), expected);
    }
    let response = client
        .get(&url)
        .header("range", "bytes=10-")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 416);
    assert_eq!(response.headers()["content-range"], "bytes */10");
    manager.close(&session.session).await.unwrap();
    assert_eq!(client.get(&url).send().await.unwrap().status(), 404);
    manager.shutdown().await;
    lb.task.abort();
}

#[tokio::test]
async fn old_generation_cannot_close_new_session() {
    let dir = TempDir::new("media-generation");
    let manager = MediaManager::new(dir.path().join("runtime"), 9);
    let file = dir.path().join("audio.mp3");
    std::fs::write(&file, b"audio").unwrap();
    let session = manager
        .create(
            "new".into(),
            MediaSource::LocalFile {
                path: file.to_string_lossy().into(),
            },
            None,
        )
        .await
        .unwrap();
    let old = MediaSessionRef {
        id: session.session.id.clone(),
        generation: 8,
    };
    assert!(manager.close(&old).await.is_err());
    assert!(manager.lookup(&session.session.id).is_some());
    manager.shutdown().await;
}

#[tokio::test]
async fn early_cancel_is_consumed_and_no_session_is_published() {
    let dir = TempDir::new("media-pre-cancel");
    let manager = MediaManager::new(dir.path().join("runtime"), 1);
    assert!(!manager.cancel("early"));
    let result = manager
        .create(
            "early".into(),
            MediaSource::LocalFile {
                path: dir.path().join("absent").to_string_lossy().into(),
            },
            None,
        )
        .await;
    assert_eq!(result.unwrap_err().code, "cancelled");
    assert_eq!(manager.counts(), (0, 0));
}

use axum::{
    body::Body,
    http::{header, StatusCode},
    response::Response,
};
use std::sync::atomic::{AtomicU8, AtomicUsize, Ordering};
use tokio::sync::Semaphore;

struct MockMedia {
    origin: String,
    mode: Arc<AtomicU8>,
    entered: Arc<Semaphore>,
    requests: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}
impl MockMedia {
    async fn start(bytes: Vec<u8>) -> Self {
        let mode = Arc::new(AtomicU8::new(0));
        let entered = Arc::new(Semaphore::new(0));
        let requests = Arc::new(AtomicUsize::new(0));
        let state = (
            Arc::new(bytes),
            mode.clone(),
            entered.clone(),
            requests.clone(),
        );
        let app = axum::Router::new().fallback(move |req: axum::extract::Request| {
            let (bytes, mode, entered, requests) = state.clone();
            async move {
                requests.fetch_add(1, Ordering::SeqCst);
                let range = req
                    .headers()
                    .get("range")
                    .unwrap()
                    .to_str()
                    .unwrap()
                    .strip_prefix("bytes=")
                    .unwrap();
                let (start, end) = range.split_once('-').unwrap();
                let start: usize = start.parse().unwrap();
                let end: usize = end.parse().unwrap();
                let behavior = mode.load(Ordering::SeqCst);
                if behavior == 1 || (behavior == 2 && end > 0) {
                    entered.add_permits(1);
                    std::future::pending::<()>().await;
                }
                let data = bytes[start..=end].to_vec();
                let total = bytes.len();
                let mut builder = Response::builder()
                    .status(StatusCode::PARTIAL_CONTENT)
                    .header(header::CONTENT_TYPE, "video/mp4")
                    .header(
                        header::CONTENT_RANGE,
                        format!(
                            "bytes {start}-{end}/{}",
                            if behavior == 5 && end > 0 {
                                total + 1
                            } else {
                                total
                            }
                        ),
                    );
                if behavior == 6 && end > 0 {
                    builder = builder.header(header::CONTENT_ENCODING, "gzip");
                }
                let body = if behavior == 3 && end > 0 {
                    Body::from(data[..data.len() - 1].to_vec())
                } else if behavior == 4 && end > 0 {
                    entered.add_permits(1);
                    Body::from_stream(futures::stream::once(std::future::pending::<
                        Result<Vec<u8>, std::io::Error>,
                    >()))
                } else {
                    builder = builder.header(header::CONTENT_LENGTH, data.len());
                    Body::from(data)
                };
                builder.body(body).unwrap()
            }
        });
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        Self {
            origin,
            mode,
            entered,
            requests,
            task,
        }
    }
    async fn wait_entered(&self) {
        tokio::time::timeout(Duration::from_secs(2), self.entered.acquire())
            .await
            .expect("request reached parked upstream")
            .unwrap()
            .forget();
    }
}
impl Drop for MockMedia {
    fn drop(&mut self) {
        self.task.abort();
    }
}
fn remote() -> MediaSource {
    MediaSource::RemoteHttps {
        url: "https://fixture.invalid/media.mp4".into(),
    }
}
fn key() -> Option<Vec<u8>> {
    Some(hex::decode("00112233445566778899aabbccddeeff").unwrap())
}
fn fixture(dir: &TempDir) -> (Vec<u8>, Vec<u8>) {
    let script = "const fs=require('fs');const f=require('./test/support/cenc_fixture.cjs').makeFixture({tracks:[{samples:[131109,81937]}]});fs.writeFileSync(process.argv[1],f.encrypted);fs.writeFileSync(process.argv[2],f.expected);";
    let encrypted = dir.path().join("encrypted.mp4");
    let plain = dir.path().join("plain.mp4");
    let status = std::process::Command::new("node")
        .current_dir(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .parent()
                .unwrap(),
        )
        .args(["-e", script])
        .arg(&encrypted)
        .arg(&plain)
        .status()
        .unwrap();
    assert!(status.success());
    (
        std::fs::read(encrypted).unwrap(),
        std::fs::read(plain).unwrap(),
    )
}

#[tokio::test]
async fn cancelled_open_publishes_no_session() {
    let dir = TempDir::new("media-cancel-open");
    let mock = MockMedia::start(vec![1; 100]).await;
    mock.mode.store(1, Ordering::SeqCst);
    let manager =
        MediaManager::with_test_transport(dir.path().join("runtime"), 1, mock.origin.clone());
    let pending = tokio::spawn({
        let manager = manager.clone();
        async move { manager.create("open".into(), remote(), None).await }
    });
    mock.wait_entered().await;
    assert_eq!(manager.counts(), (0, 1));
    assert!(manager.cancel("open"));
    let result = tokio::time::timeout(Duration::from_secs(2), pending)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(result.unwrap_err().code, "cancelled");
    assert_eq!(manager.counts(), (0, 0));
    mock.mode.store(0, Ordering::SeqCst);
    assert!(manager.create("fresh".into(), remote(), None).await.is_ok());
    manager.shutdown().await;
}

#[tokio::test]
async fn seek_after_request_cancel_returns_expected_plain_bytes() {
    let dir = TempDir::new("media-seek-cancel");
    let (encrypted, expected) = fixture(&dir);
    let mock = MockMedia::start(encrypted).await;
    let manager =
        MediaManager::with_test_transport(dir.path().join("runtime"), 1, mock.origin.clone());
    let meta = manager
        .create("encrypted".into(), remote(), key())
        .await
        .unwrap();
    let session = manager.lookup(&meta.session.id).unwrap();
    for mode in [2, 4] {
        mock.mode.store(mode, Ordering::SeqCst);
        let token = session.request_token();
        let pending = tokio::spawn({
            let session = session.clone();
            let token = token.clone();
            async move { session.read(session.length - 64, 64, token).await }
        });
        mock.wait_entered().await;
        token.cancel();
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(2), pending)
                .await
                .unwrap()
                .unwrap()
                .unwrap_err()
                .code,
            "cancelled"
        );
        mock.mode.store(0, Ordering::SeqCst);
        let bytes = session
            .read(session.length - 64, 64, session.request_token())
            .await
            .unwrap();
        assert_eq!(bytes, expected[expected.len() - 64..]);
    }
    manager.close(&meta.session).await.unwrap();
}

#[tokio::test]
async fn parked_three_plus_active_plus_pending_open_is_allowed() {
    let dir = TempDir::new("media-capacity");
    let mock = MockMedia::start(vec![5; 1024]).await;
    let manager =
        MediaManager::with_test_transport(dir.path().join("runtime"), 1, mock.origin.clone());
    let mut sessions = Vec::new();
    for i in 0..4 {
        sessions.push(
            manager
                .create(format!("parked-{i}"), remote(), None)
                .await
                .unwrap(),
        );
    }
    let active = manager.lookup(&sessions[3].session.id).unwrap();
    mock.mode.store(2, Ordering::SeqCst);
    let read = tokio::spawn({
        let active = active.clone();
        async move { active.read(1, 64, active.request_token()).await }
    });
    mock.wait_entered().await;
    mock.mode.store(1, Ordering::SeqCst);
    let pending = tokio::spawn({
        let manager = manager.clone();
        async move { manager.create("pending".into(), remote(), None).await }
    });
    mock.wait_entered().await;
    assert_eq!(manager.counts(), (4, 1));
    manager.cancel("pending");
    assert_eq!(pending.await.unwrap().unwrap_err().code, "cancelled");
    tokio::time::timeout(Duration::from_secs(2), manager.shutdown())
        .await
        .unwrap();
    assert_eq!(read.await.unwrap().unwrap_err().code, "cancelled");
}

#[tokio::test]
async fn closing_waiting_headers_revokes_route_and_keeps_core_responsive() {
    let dir = TempDir::new("media-close-headers");
    let mock = MockMedia::start(vec![5; 1024]).await;
    let manager =
        MediaManager::with_test_transport(dir.path().join("runtime"), 1, mock.origin.clone());
    let server = build_server(&dir, None, &[], &[], &pool_json(3)).await;
    let lb = fqapi_core::server::serve_with_media(server, 0, manager.clone())
        .await
        .unwrap();
    let meta = manager
        .create("close-headers".into(), remote(), None)
        .await
        .unwrap();
    let base = format!("http://127.0.0.1:{}/_session/{}", lb.port, lb.token);
    let url = format!("{base}/media/{}", meta.session.id);
    mock.mode.store(2, Ordering::SeqCst);
    let pending = tokio::spawn({
        let url = url.clone();
        async move {
            match reqwest::get(url).await {
                Ok(response) => response.bytes().await.map(|_| ()),
                Err(e) => Err(e),
            }
        }
    });
    mock.wait_entered().await;
    assert_eq!(
        tokio::time::timeout(
            Duration::from_secs(2),
            reqwest::get(format!("{base}/health"))
        )
        .await
        .unwrap()
        .unwrap()
        .status(),
        200
    );
    tokio::time::timeout(Duration::from_secs(2), manager.close(&meta.session))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(reqwest::get(url).await.unwrap().status(), 404);
    assert!(tokio::time::timeout(Duration::from_secs(2), pending)
        .await
        .unwrap()
        .unwrap()
        .is_err());
    assert_eq!(manager.counts(), (0, 0));
    manager.shutdown().await;
    lb.task.abort();
}

#[tokio::test]
async fn short_read_is_an_error_and_disconnect_does_not_poison_next_seek() {
    let dir = TempDir::new("media-short-disconnect");
    let mock = MockMedia::start(vec![7; 262144]).await;
    let manager =
        MediaManager::with_test_transport(dir.path().join("runtime"), 1, mock.origin.clone());
    let server = build_server(&dir, None, &[], &[], &pool_json(3)).await;
    let lb = fqapi_core::server::serve_with_media(server, 0, manager.clone())
        .await
        .unwrap();
    let meta = manager
        .create("short".into(), remote(), None)
        .await
        .unwrap();
    let url = format!(
        "http://127.0.0.1:{}/_session/{}/media/{}",
        lb.port, lb.token, meta.session.id
    );
    let session = manager.lookup(&meta.session.id).unwrap();
    mock.mode.store(3, Ordering::SeqCst);
    assert_eq!(
        session
            .read(1, 64, session.request_token())
            .await
            .unwrap_err()
            .code,
        "io"
    );
    // A raw HTTP peer disconnects after requesting a body whose upstream waits.
    use tokio::io::AsyncWriteExt;
    mock.mode.store(2, Ordering::SeqCst);
    let mut socket = tokio::net::TcpStream::connect(("127.0.0.1", lb.port))
        .await
        .unwrap();
    socket
        .write_all(
            format!(
                "GET /_session/{}/media/{} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n\r\n",
                lb.token, meta.session.id, lb.port
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    mock.wait_entered().await;
    drop(socket);
    mock.mode.store(0, Ordering::SeqCst);
    let response = tokio::time::timeout(
        Duration::from_secs(2),
        reqwest::Client::new()
            .get(url)
            .header("range", "bytes=-64")
            .send(),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(response.status(), 206);
    assert_eq!(response.bytes().await.unwrap(), vec![7; 64]);
    manager.shutdown().await;
    lb.task.abort();
}

#[tokio::test]
async fn local_path_escape_https_and_session_capacity_fail_closed() {
    let dir = TempDir::new("media-paths");
    let support = dir.path().join("support");
    std::fs::create_dir_all(&support).unwrap();
    let manager = MediaManager::new(support.join("runtime"), 1);
    let outside = dir.path().join("outside.mp4");
    std::fs::write(&outside, b"content").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&outside, support.join("escape.mp4")).unwrap();
    for path in [outside, support.join("escape.mp4")] {
        assert_eq!(
            manager
                .create(
                    "escape".into(),
                    MediaSource::LocalFile {
                        path: path.to_string_lossy().into()
                    },
                    None
                )
                .await
                .unwrap_err()
                .code,
            "invalid_source"
        );
    }
    assert_eq!(
        manager
            .create(
                "http".into(),
                MediaSource::RemoteHttps {
                    url: "http://127.0.0.1/file".into()
                },
                None
            )
            .await
            .unwrap_err()
            .code,
        "invalid_source"
    );
    let file = support.join("good.mp3");
    std::fs::write(&file, b"content").unwrap();
    for i in 0..8 {
        manager
            .create(
                format!("slot{i}"),
                MediaSource::LocalFile {
                    path: file.to_string_lossy().into(),
                },
                None,
            )
            .await
            .unwrap();
    }
    assert_eq!(
        manager
            .create(
                "overflow".into(),
                MediaSource::LocalFile {
                    path: file.to_string_lossy().into()
                },
                None
            )
            .await
            .unwrap_err()
            .code,
        "busy"
    );
    manager.shutdown().await;
}

#[tokio::test]
async fn cancellation_during_c_open_and_abandoned_create_drain_all_workers() {
    let dir = TempDir::new("media-c-open");
    let (bytes, _) = fixture(&dir);
    let mock = MockMedia::start(bytes).await;
    mock.mode.store(2, Ordering::SeqCst);
    let manager =
        MediaManager::with_test_transport(dir.path().join("runtime"), 1, mock.origin.clone());
    let pending = tokio::spawn({
        let manager = manager.clone();
        async move { manager.create("c-open".into(), remote(), key()).await }
    });
    mock.wait_entered().await;
    assert!(manager.cancel("c-open"));
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(2), pending)
            .await
            .unwrap()
            .unwrap()
            .unwrap_err()
            .code,
        "cancelled"
    );
    assert_eq!(manager.counts(), (0, 0));
    let abandoned = tokio::spawn({
        let manager = manager.clone();
        async move { manager.create("abandoned".into(), remote(), key()).await }
    });
    mock.wait_entered().await;
    abandoned.abort();
    let _ = abandoned.await;
    tokio::time::timeout(Duration::from_secs(2), manager.shutdown())
        .await
        .unwrap();
    assert_eq!(manager.active_workers(), 0);
}

#[tokio::test]
async fn only_two_openings_and_four_queued_operations_are_admitted() {
    let dir = TempDir::new("media-queue-bounds");
    let mock = MockMedia::start(vec![9; 1024]).await;
    let manager =
        MediaManager::with_test_transport(dir.path().join("runtime"), 1, mock.origin.clone());
    let meta = manager
        .create("active".into(), remote(), None)
        .await
        .unwrap();
    let session = manager.lookup(&meta.session.id).unwrap();
    mock.mode.store(1, Ordering::SeqCst);
    let mut opens = Vec::new();
    for i in 0..2 {
        opens.push(tokio::spawn({
            let manager = manager.clone();
            async move { manager.create(format!("open-{i}"), remote(), None).await }
        }));
        mock.wait_entered().await;
    }
    assert_eq!(
        manager
            .create("open-3".into(), remote(), None)
            .await
            .unwrap_err()
            .code,
        "busy"
    );
    let read = tokio::spawn({
        let session = session.clone();
        async move { session.read(2, 64, session.request_token()).await }
    });
    mock.wait_entered().await;
    // Poll five read futures once while the worker is blocked: four enqueue,
    // and the fifth fails immediately with busy.
    let mut queued = Vec::new();
    for _ in 0..4 {
        let mut future = Box::pin(session.read(2, 64, session.request_token()));
        assert!(matches!(
            futures::poll!(future.as_mut()),
            std::task::Poll::Pending
        ));
        queued.push(future);
    }
    assert_eq!(
        session
            .read(2, 64, session.request_token())
            .await
            .unwrap_err()
            .code,
        "busy"
    );
    drop(queued);
    tokio::time::timeout(Duration::from_secs(2), manager.shutdown())
        .await
        .unwrap();
    assert_eq!(read.await.unwrap().unwrap_err().code, "cancelled");
    for open in opens {
        assert_eq!(open.await.unwrap().unwrap_err().code, "cancelled");
    }
    assert_eq!(manager.active_workers(), 0);
}

#[tokio::test]
async fn encrypted_loopback_full_and_random_ranges_match_independent_fixture() {
    let dir = TempDir::new("media-encrypted-http");
    let (bytes, expected) = fixture(&dir);
    let mock = MockMedia::start(bytes).await;
    let manager =
        MediaManager::with_test_transport(dir.path().join("runtime"), 1, mock.origin.clone());
    let server = build_server(&dir, None, &[], &[], &pool_json(3)).await;
    let lb = fqapi_core::server::serve_with_media(server, 0, manager.clone())
        .await
        .unwrap();
    let meta = manager
        .create("encrypted-http".into(), remote(), key())
        .await
        .unwrap();
    let url = format!(
        "http://127.0.0.1:{}/_session/{}/media/{}",
        lb.port, lb.token, meta.session.id
    );
    let client = reqwest::Client::new();
    assert_eq!(
        client
            .get(&url)
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap(),
        expected
    );
    for (start, len) in [
        (0, 7),
        (512, 1024),
        (65530, 31),
        (131101, 97),
        (expected.len() - 73, 73),
    ] {
        let response = client
            .get(&url)
            .header("range", format!("bytes={start}-{}", start + len - 1))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 206);
        assert_eq!(
            response.bytes().await.unwrap(),
            expected[start..start + len]
        );
    }
    manager.shutdown().await;
    lb.task.abort();
}

#[tokio::test]
async fn core_restart_retires_old_media_routes_and_session_references() {
    use fqapi_core::api;
    let dir = TempDir::new("media-core-restart");
    let _server = build_server(&dir, None, &[], &[], &pool_json(3)).await;
    let file = dir.join("restart.mp3");
    std::fs::write(&file, b"restart").unwrap();
    let init = || {
        api::init(
            dir.join("config/config.json").to_string_lossy().into(),
            dir.join("config/device_pool.json").to_string_lossy().into(),
            dir.join("config/filter.json").to_string_lossy().into(),
            dir.path().to_string_lossy().into(),
            0,
            String::new(),
        )
    };
    init().await.unwrap();
    let old = api::media::media_create(
        "core-old".into(),
        MediaSource::LocalFile {
            path: file.to_string_lossy().into(),
        },
        None,
    )
    .await
    .unwrap();
    assert_eq!(reqwest::get(&old.playback_url).await.unwrap().status(), 200);
    api::shutdown().await.unwrap();
    init().await.unwrap();
    let fresh = api::media::media_create(
        "core-fresh".into(),
        MediaSource::LocalFile {
            path: file.to_string_lossy().into(),
        },
        None,
    )
    .await
    .unwrap();
    assert!(fresh.session.generation > old.session.generation);
    assert_eq!(
        api::media::media_close(old.session).await.unwrap_err().code,
        "unavailable"
    );
    assert_eq!(
        reqwest::get(&fresh.playback_url).await.unwrap().status(),
        200
    );
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .unwrap();
    assert!(client
        .get(&old.playback_url)
        .send()
        .await
        .map_or(true, |r| r.status() != 200));
    api::shutdown().await.unwrap();
}

#[tokio::test]
async fn changed_upstream_length_or_content_encoding_is_rejected() {
    let dir = TempDir::new("media-response-validation");
    let mock = MockMedia::start(vec![3; 1024]).await;
    let manager =
        MediaManager::with_test_transport(dir.path().join("runtime"), 1, mock.origin.clone());
    let meta = manager
        .create("validation".into(), remote(), None)
        .await
        .unwrap();
    let session = manager.lookup(&meta.session.id).unwrap();
    for mode in [5, 6] {
        mock.mode.store(mode, Ordering::SeqCst);
        assert_eq!(
            session
                .read(1, 64, session.request_token())
                .await
                .unwrap_err()
                .code,
            "io"
        );
    }
    manager.shutdown().await;
}

#[tokio::test]
async fn unconsumed_body_stops_upstream_after_two_output_blocks() {
    let dir = TempDir::new("media-backpressure");
    let mock = MockMedia::start(vec![8; 4 * 1024 * 1024]).await;
    let manager =
        MediaManager::with_test_transport(dir.path().join("runtime"), 1, mock.origin.clone());
    let meta = manager
        .create("backpressure".into(), remote(), None)
        .await
        .unwrap();
    let response =
        fqapi_core::native_media::http::response(&manager, &meta.session.id, "GET", None).await;
    tokio::time::timeout(Duration::from_secs(2), async {
        while mock.requests.load(Ordering::SeqCst) < 3 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    tokio::time::sleep(Duration::from_millis(30)).await;
    // One length probe plus exactly two output reads; an unconsumed HTTP body
    // must not trigger a third speculative media read or buffer the full file.
    assert_eq!(mock.requests.load(Ordering::SeqCst), 3);
    drop(response);
    tokio::time::timeout(Duration::from_secs(2), manager.shutdown())
        .await
        .unwrap();
    assert_eq!(manager.active_workers(), 0);
}
