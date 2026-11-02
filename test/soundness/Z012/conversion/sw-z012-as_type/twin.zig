// The same, public.
pub const Hidden = @as(type, struct { x: u8 });
pub fn make() Hidden {
    return .{ .x = 1 };
}
