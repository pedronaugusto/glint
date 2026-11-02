// The same block-given type, public.
pub const Hidden = blk: {
    break :blk struct { x: u8 };
};
pub fn make() Hidden {
    return .{ .x = 1 };
}
