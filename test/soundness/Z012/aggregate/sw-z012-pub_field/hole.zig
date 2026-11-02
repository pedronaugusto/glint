// A public struct's field of a private type.
const Hidden = struct { x: u8 };
pub const Api = struct {
    inner: Hidden,
};
