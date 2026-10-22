//! C objects never leave their owning dedicated worker thread.
use super::source::Source;
use crate::api::media::MediaError;
use std::ffi::{c_char, c_void};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

#[repr(C)]
struct SpError {
    code: i32,
    message: [c_char; 192],
}
impl Default for SpError {
    fn default() -> Self {
        Self {
            code: 0,
            message: [0; 192],
        }
    }
}
#[repr(C)]
struct SpIo {
    user: *mut c_void,
    size: extern "C" fn(*mut c_void) -> i64,
    read_at: extern "C" fn(*mut c_void, u64, *mut u8, usize) -> isize,
    cancel: extern "C" fn(*mut c_void),
    close: extern "C" fn(*mut c_void),
}
unsafe extern "C" {
    fn sp_stream_open(io: *const SpIo, key: *const u8, error: *mut SpError) -> *mut c_void;
    fn sp_stream_read(
        stream: *mut c_void,
        buffer: *mut u8,
        length: usize,
        error: *mut SpError,
    ) -> isize;
    fn sp_stream_seek(stream: *mut c_void, position: i64, error: *mut SpError) -> i64;
    fn sp_stream_cancel(stream: *mut c_void);
    fn sp_stream_close(stream: *mut c_void);
}
extern "C" fn io_size(user: *mut c_void) -> i64 {
    unsafe { (*(user as *mut Source)).size as i64 }
}
extern "C" fn io_read(user: *mut c_void, offset: u64, buffer: *mut u8, length: usize) -> isize {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
        let source = &mut *(user as *mut Source);
        match source.read_at(offset, std::slice::from_raw_parts_mut(buffer, length)) {
            Ok(n) => n as isize,
            Err(error) => {
                source.error = Some(error);
                -1
            }
        }
    }))
    .unwrap_or(-1)
}
extern "C" fn io_cancel(user: *mut c_void) {
    // C calls this during seek, on the same worker, before the next operation
    // token is installed. Remote disconnect cancellation uses the token directly.
    unsafe {
        (*(user as *mut Source)).operation.cancel();
    }
}
extern "C" fn io_close(user: *mut c_void) {
    unsafe {
        drop(Box::from_raw(user as *mut Source));
    }
}

pub(super) enum Reader {
    Clear(Box<Source>),
    Encrypted {
        stream: *mut c_void,
        source: *mut Source,
    },
}
impl Reader {
    pub fn open(source: Source, key: Option<Zeroizing<Vec<u8>>>) -> Result<Self, MediaError> {
        let Some(key) = key else {
            return Ok(Self::Clear(Box::new(source)));
        };
        if key.len() != 16 {
            return Err(MediaError::new("invalid_source"));
        }
        let source = Box::into_raw(Box::new(source));
        let io = SpIo {
            user: source.cast(),
            size: io_size,
            read_at: io_read,
            cancel: io_cancel,
            close: io_close,
        };
        let mut error = SpError::default();
        let stream = unsafe { sp_stream_open(&io, key.as_ptr(), &mut error) };
        if stream.is_null() {
            let mut source = unsafe { Box::from_raw(source) };
            return Err(source.error.take().unwrap_or_else(|| {
                MediaError::new(if error.code == -4 {
                    "cancelled"
                } else {
                    "unsupported"
                })
            }));
        }
        Ok(Self::Encrypted { stream, source })
    }

    pub fn read_at(
        &mut self,
        offset: u64,
        length: usize,
        operation: CancellationToken,
    ) -> Result<Vec<u8>, MediaError> {
        let mut buffer = vec![0; length];
        let count = match self {
            Self::Clear(source) => {
                source.operation = operation;
                source.read_at(offset, &mut buffer)?
            }
            Self::Encrypted { stream, source } => unsafe {
                let mut error = SpError::default();
                // seek+read is one worker command; no other request can move
                // the C cursor between these calls. seek cancels the OLD token.
                if sp_stream_seek(*stream, offset as i64, &mut error) < 0 {
                    return Err(MediaError::new("io"));
                }
                (**source).operation = operation;
                (**source).error = None;
                let count = sp_stream_read(*stream, buffer.as_mut_ptr(), length, &mut error);
                if count < 0 {
                    return Err((**source)
                        .error
                        .take()
                        .unwrap_or_else(|| MediaError::new("io")));
                }
                count as usize
            },
        };
        // A zero-length successful read before the promised end is an error.
        if count == 0 || count > length {
            return Err(MediaError::new("io"));
        }
        buffer.truncate(count);
        Ok(buffer)
    }
}
impl Drop for Reader {
    fn drop(&mut self) {
        if let Self::Encrypted { stream, .. } = self {
            // Permanent C cancellation is only used at terminal teardown.
            unsafe {
                sp_stream_cancel(*stream);
                sp_stream_close(*stream);
            }
        }
    }
}
