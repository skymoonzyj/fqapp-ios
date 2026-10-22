//! Bounded native media workers shared by the bridge and guarded HTTP adapter.
pub mod http;
pub mod session;
mod source;
mod stream;

pub const BLOCK_SIZE: usize = 64 * 1024;
pub const MAX_SESSIONS: usize = 8;
pub const MAX_OPENING: usize = 2;
pub const MAX_QUEUED: usize = 4;
pub const BODY_BLOCKS: usize = 2;
