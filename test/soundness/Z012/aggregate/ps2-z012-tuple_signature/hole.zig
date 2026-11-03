const Hidden = struct { x: u8 };
pub fn pair() struct { Hidden, u8 } {
    return .{ .{ .x = 1 }, 2 };
}
