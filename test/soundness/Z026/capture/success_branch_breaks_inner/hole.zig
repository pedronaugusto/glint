// Z026: an empty error branch whose success branch breaks only out of its own block
fn parse(s: []const u8) error{Bad}!u32 {
    if (s.len == 0) return error.Bad;
    return @intCast(s.len);
}
pub fn width(s: []const u8) u32 {
    if (parse(s)) |_| blk: {
        break :blk;
    } else |_| {}
    return 8;
}
