pub const Hidden = struct { x: u8 };
const Impl = struct { inner: Hidden };
/// Callers reach Impl through this alias, and its field's type through it.
pub const Api = Impl;
