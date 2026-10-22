use super::{session::MediaManager, BLOCK_SIZE, BODY_BLOCKS};
use axum::{
    body::Body,
    http::{header, StatusCode},
    response::{IntoResponse, Response},
};
use futures::stream;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio_util::sync::DropGuard;

pub async fn response(
    manager: &Arc<MediaManager>,
    id: &str,
    method: &str,
    range: Option<&str>,
) -> Response {
    let Some(session) = manager.lookup(id) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if method != "GET" && method != "HEAD" {
        return StatusCode::METHOD_NOT_ALLOWED.into_response();
    }
    let length = session.length;
    let requested = if method == "HEAD" { None } else { range };
    let Some((start, end)) = range_bounds(requested, length) else {
        return Response::builder()
            .status(416)
            .header(header::CONTENT_RANGE, format!("bytes */{length}"))
            .body(Body::empty())
            .unwrap();
    };
    let mut builder = Response::builder()
        .status(if requested.is_some() { 206 } else { 200 })
        .header(header::CONTENT_TYPE, &session.content_type)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_LENGTH, end - start + 1)
        .header(header::CACHE_CONTROL, "no-store")
        .header(header::REFERRER_POLICY, "no-referrer");
    if requested.is_some() {
        builder = builder.header(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{length}"),
        );
    }
    if method == "HEAD" {
        return builder.body(Body::empty()).unwrap();
    }
    let token = session.request_token();
    let body_guard = token.clone().drop_guard();
    let (tx, rx) = mpsc::channel(BODY_BLOCKS);
    tokio::spawn(async move {
        let _producer_guard = token.clone().drop_guard();
        let mut offset = start;
        while offset <= end {
            // Reserve before reading: at most two output blocks exist, even
            // when the HTTP client stops consuming and backpressure reaches us.
            let permit = tokio::select! {
                biased;
                _ = token.cancelled() => break,
                permit = tx.reserve() => match permit { Ok(p) => p, Err(_) => break },
            };
            match session
                .read(
                    offset,
                    BLOCK_SIZE.min((end - offset + 1) as usize),
                    token.clone(),
                )
                .await
            {
                Ok(bytes) => {
                    offset += bytes.len() as u64;
                    permit.send(Ok::<_, std::io::Error>(bytes));
                }
                Err(error) => {
                    permit.send(Err(std::io::Error::other(error.message)));
                    break;
                }
            }
        }
    });
    let body = stream::unfold(
        (rx, body_guard),
        |(mut rx, guard): (
            mpsc::Receiver<std::result::Result<Vec<u8>, std::io::Error>>,
            DropGuard,
        )| async move { rx.recv().await.map(|chunk| (chunk, (rx, guard))) },
    );
    builder.body(Body::from_stream(body)).unwrap()
}

fn range_bounds(range: Option<&str>, length: u64) -> Option<(u64, u64)> {
    if length == 0 {
        return None;
    }
    let Some(range) = range else {
        return Some((0, length - 1));
    };
    let (start, end) = range.strip_prefix("bytes=")?.split_once('-')?;
    if start.is_empty() {
        let suffix: u64 = end.parse().ok()?;
        if suffix == 0 {
            return None;
        }
        return Some((length.saturating_sub(suffix), length - 1));
    }
    let start: u64 = start.parse().ok()?;
    let end: u64 = if end.is_empty() {
        length - 1
    } else {
        end.parse().ok()?
    };
    (start < length && start <= end).then_some((start, end.min(length - 1)))
}
