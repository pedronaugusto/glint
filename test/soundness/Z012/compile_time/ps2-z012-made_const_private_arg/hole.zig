const Hidden = struct { x: u8 };
pub fn Box(comptime T: type) type {
    return struct { inner: T };
}
/// A public name for Box(Hidden): its field `inner` is a Hidden callers cannot name.
pub const Boxed = Box(Hidden);
