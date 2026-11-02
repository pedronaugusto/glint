// The same, its type declared public.
pub const Hidden = struct { x: u8 };
pub const Api = struct {
    inner: Hidden,
};
