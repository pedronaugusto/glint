// The same, its type declared public.
pub const Hidden = struct { x: u8 };
pub fn make() Hidden {
    return .{ .x = 1 };
}
