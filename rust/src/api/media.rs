//! Stable bridge types on every target. Unsupported targets fail closed.

#[derive(Clone, Debug)]
pub enum MediaSource {
    RemoteHttps { url: String },
    LocalFile { path: String },
}

#[derive(Clone, Debug)]
pub struct MediaSessionRef {
    pub id: String,
    pub generation: u64,
}

#[derive(Clone, Debug)]
pub struct MediaSession {
    pub session: MediaSessionRef,
    pub playback_url: String,
    pub content_length: u64,
    pub content_type: String,
}

#[derive(Clone, Debug)]
pub struct MediaError {
    pub code: String,
    pub message: String,
}

impl std::fmt::Display for MediaError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for MediaError {}

impl MediaError {
    pub(crate) fn new(code: &str) -> Self {
        let message = match code {
            "cancelled" => "Media operation cancelled",
            "timeout" => "Media operation timed out",
            "invalid_source" => "Invalid media source",
            "unsupported" => "Unsupported media format",
            "busy" => "Media capacity reached",
            "io" => "Media read failed",
            _ => "Media unavailable",
        };
        Self {
            code: code.to_owned(),
            message: message.to_owned(),
        }
    }
}

pub async fn media_create(
    request_id: String,
    source: MediaSource,
    key: Option<Vec<u8>>,
) -> Result<MediaSession, MediaError> {
    #[cfg(any(
        target_os = "ios",
        all(
            feature = "native-media-host-tests",
            any(target_os = "macos", target_os = "linux")
        )
    ))]
    {
        let core = super::CORE
            .read()
            .await
            .clone()
            .ok_or_else(|| MediaError::new("unavailable"))?;
        let mut session = core.media.create(request_id, source, key).await?;
        session.playback_url = format!(
            "http://127.0.0.1:{}/_session/{}/media/{}",
            core.port, core.token, session.session.id
        );
        Ok(session)
    }
    #[cfg(not(any(
        target_os = "ios",
        all(
            feature = "native-media-host-tests",
            any(target_os = "macos", target_os = "linux")
        )
    )))]
    {
        let _ = (request_id, source, key);
        Err(MediaError::new("unavailable"))
    }
}

pub async fn media_cancel(request_id: String) -> bool {
    #[cfg(any(
        target_os = "ios",
        all(
            feature = "native-media-host-tests",
            any(target_os = "macos", target_os = "linux")
        )
    ))]
    {
        super::CORE
            .read()
            .await
            .as_ref()
            .is_some_and(|core| core.media.cancel(&request_id))
    }
    #[cfg(not(any(
        target_os = "ios",
        all(
            feature = "native-media-host-tests",
            any(target_os = "macos", target_os = "linux")
        )
    )))]
    {
        let _ = request_id;
        false
    }
}

pub async fn media_close(session: MediaSessionRef) -> Result<(), MediaError> {
    #[cfg(any(
        target_os = "ios",
        all(
            feature = "native-media-host-tests",
            any(target_os = "macos", target_os = "linux")
        )
    ))]
    {
        let core = super::CORE
            .read()
            .await
            .clone()
            .ok_or_else(|| MediaError::new("unavailable"))?;
        core.media.close(&session).await
    }
    #[cfg(not(any(
        target_os = "ios",
        all(
            feature = "native-media-host-tests",
            any(target_os = "macos", target_os = "linux")
        )
    )))]
    {
        let _ = session;
        Err(MediaError::new("unavailable"))
    }
}
