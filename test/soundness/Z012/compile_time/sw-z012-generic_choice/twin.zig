// The same, its type declared public.
pub const Hidden = struct { x: u8 };
pub fn make(comptime T: type) if (T == u8) Hidden else T {
    return undefined;
}
