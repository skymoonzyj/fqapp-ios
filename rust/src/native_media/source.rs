use super::BLOCK_SIZE;
use crate::api::media::{MediaError, MediaSource};
use reqwest::{header, Client};
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::Path,
    time::Duration,
};
use tokio_util::sync::CancellationToken;

type Result<T> = std::result::Result<T, MediaError>;

pub(super) struct Source {
    file: Option<File>,
    remote: Option<(Client, String)>,
    pub size: u64,
    pub content_type: String,
    runtime: tokio::runtime::Handle,
    root: CancellationToken,
    pub operation: CancellationToken,
    pub error: Option<MediaError>,
}

impl Source {
    pub fn open(
        source: MediaSource,
        root_dir: &Path,
        root: CancellationToken,
        runtime: tokio::runtime::Handle,
        test_origin: Option<String>,
    ) -> Result<Self> {
        let mut result = Self {
            file: None,
            remote: None,
            size: 0,
            content_type: "application/octet-stream".into(),
            runtime,
            operation: root.child_token(),
            root,
            error: None,
        };
        if result.root.is_cancelled() {
            return Err(MediaError::new("cancelled"));
        }
        match source {
            MediaSource::LocalFile { path } => {
                let trusted = root_dir
                    .parent()
                    .ok_or_else(|| MediaError::new("invalid_source"))?
                    .canonicalize()
                    .map_err(|_| MediaError::new("invalid_source"))?;
                let path = Path::new(&path)
                    .canonicalize()
                    .map_err(|_| MediaError::new("invalid_source"))?;
                if !path.starts_with(&trusted) {
                    return Err(MediaError::new("invalid_source"));
                }
                // Reject special files before open: opening a FIFO could block
                // forever without ever reaching the cancellable read path.
                if !std::fs::metadata(&path)
                    .map_err(|_| MediaError::new("invalid_source"))?
                    .is_file()
                {
                    return Err(MediaError::new("invalid_source"));
                }
                let file = File::open(&path).map_err(|_| MediaError::new("io"))?;
                let metadata = file.metadata().map_err(|_| MediaError::new("io"))?;
                if !metadata.is_file() {
                    return Err(MediaError::new("invalid_source"));
                }
                result.size = metadata.len();
                result.content_type = match path.extension().and_then(|e| e.to_str()) {
                    Some("mp3") => "audio/mpeg",
                    Some("m4a") => "audio/mp4",
                    Some("mp4") => "video/mp4",
                    Some("aac") => "audio/aac",
                    _ => "application/octet-stream",
                }
                .into();
                result.file = Some(file);
            }
            MediaSource::RemoteHttps { url } => {
                let parsed =
                    url::Url::parse(&url).map_err(|_| MediaError::new("invalid_source"))?;
                if parsed.scheme() != "https"
                    || parsed.host_str().is_none()
                    || !parsed.username().is_empty()
                    || parsed.password().is_some()
                    || parsed.fragment().is_some()
                {
                    return Err(MediaError::new("invalid_source"));
                }
                let _ = rustls::crypto::ring::default_provider().install_default();
                let builder = Client::builder()
                    .https_only(true)
                    .redirect(reqwest::redirect::Policy::none())
                    .connect_timeout(Duration::from_secs(8))
                    .timeout(Duration::from_secs(15));
                let endpoint = url;
                // Only an explicitly constructed host-test manager injects a mock.
                // Neither bridge arguments nor iOS builds expose this seam.
                #[cfg(all(feature = "native-media-host-tests", not(target_os = "ios")))]
                let (builder, endpoint) = if let Some(origin) = test_origin.as_ref() {
                    (
                        builder.https_only(false),
                        format!("{}{}", origin, parsed.path()),
                    )
                } else {
                    (builder, endpoint)
                };
                let _ = test_origin;
                let client = builder
                    .build()
                    .map_err(|_| MediaError::new("unavailable"))?;
                let (size, content_type, _) = result.runtime.block_on(fetch(
                    &client,
                    &endpoint,
                    0,
                    0,
                    None,
                    &result.root,
                    &result.operation,
                ))?;
                result.size = size;
                result.content_type = content_type;
                result.remote = Some((client, endpoint));
            }
        }
        if result.size == 0 || result.size > i64::MAX as u64 {
            return Err(MediaError::new("unsupported"));
        }
        Ok(result)
    }

    pub fn read_at(&mut self, offset: u64, buffer: &mut [u8]) -> Result<usize> {
        if self.root.is_cancelled() || self.operation.is_cancelled() {
            return Err(MediaError::new("cancelled"));
        }
        if offset >= self.size || buffer.is_empty() {
            return Ok(0);
        }
        let length = buffer
            .len()
            .min(BLOCK_SIZE)
            .min((self.size - offset) as usize);
        if let Some(file) = self.file.as_mut() {
            if file.metadata().map_err(|_| MediaError::new("io"))?.len() != self.size {
                return Err(MediaError::new("io"));
            }
            file.seek(SeekFrom::Start(offset))
                .map_err(|_| MediaError::new("io"))?;
            file.read_exact(&mut buffer[..length])
                .map_err(|_| MediaError::new("io"))?;
        } else if let Some((client, url)) = &self.remote {
            let (_, _, bytes) = self.runtime.block_on(fetch(
                client,
                url,
                offset,
                offset + length as u64 - 1,
                Some(self.size),
                &self.root,
                &self.operation,
            ))?;
            buffer[..length].copy_from_slice(&bytes);
        } else {
            return Err(MediaError::new("io"));
        }
        Ok(length)
    }
}

async fn fetch(
    client: &Client,
    url: &str,
    start: u64,
    end: u64,
    total: Option<u64>,
    root: &CancellationToken,
    operation: &CancellationToken,
) -> Result<(u64, String, Vec<u8>)> {
    let work = async {
        let mut response = client
            .get(url)
            .header(header::RANGE, format!("bytes={start}-{end}"))
            .header(header::ACCEPT_ENCODING, "identity")
            .send()
            .await
            .map_err(network_error)?;
        if response.status() != 206
            || response
                .headers()
                .get(header::CONTENT_ENCODING)
                .is_some_and(|v| v != "identity")
        {
            return Err(MediaError::new("io"));
        }
        let actual = response
            .headers()
            .get(header::CONTENT_RANGE)
            .and_then(|v| v.to_str().ok())
            .and_then(content_range)
            .ok_or_else(|| MediaError::new("io"))?;
        if actual.0 != start
            || actual.1 != end
            || actual.2 <= end
            || total.is_some_and(|t| t != actual.2)
        {
            return Err(MediaError::new("io"));
        }
        let content_type = response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .filter(|v| {
                matches!(
                    *v,
                    "video/mp4" | "audio/mp4" | "audio/mpeg" | "audio/aac" | "audio/wav"
                )
            })
            .unwrap_or("application/octet-stream")
            .to_owned();
        let expected = (end - start + 1) as usize;
        if response
            .content_length()
            .is_some_and(|n| n != expected as u64)
        {
            return Err(MediaError::new("io"));
        }
        let mut bytes = Vec::with_capacity(expected);
        while let Some(chunk) = response.chunk().await.map_err(network_error)? {
            if chunk.len() > expected - bytes.len() {
                return Err(MediaError::new("io"));
            }
            bytes.extend_from_slice(&chunk);
        }
        if bytes.len() != expected {
            return Err(MediaError::new("io"));
        }
        Ok((actual.2, content_type, bytes))
    };
    tokio::select! {
        biased;
        _ = root.cancelled() => Err(MediaError::new("cancelled")),
        _ = operation.cancelled() => Err(MediaError::new("cancelled")),
        value = tokio::time::timeout(Duration::from_secs(15), work) => value.unwrap_or_else(|_| Err(MediaError::new("timeout"))),
    }
}

fn network_error(error: reqwest::Error) -> MediaError {
    MediaError::new(if error.is_timeout() { "timeout" } else { "io" })
}
fn content_range(value: &str) -> Option<(u64, u64, u64)> {
    let (range, total) = value.strip_prefix("bytes ")?.split_once('/')?;
    let (start, end) = range.split_once('-')?;
    Some((start.parse().ok()?, end.parse().ok()?, total.parse().ok()?))
}
