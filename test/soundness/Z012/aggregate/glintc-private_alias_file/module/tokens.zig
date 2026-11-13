//! A file of the package: what reaches it decides whether its public declarations are a
//! consumer's.
const Named = struct { n: u8 };
pub const Recorder = struct { named: Named };
