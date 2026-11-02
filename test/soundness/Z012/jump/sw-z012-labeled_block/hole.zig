// A private type a labeled block gives.
const Hidden = blk: {
    break :blk struct { x: u8 };
};
pub fn make() Hidden {
    return .{ .x = 1 };
}
