// Z026 twin: the error branch counts the error
fn parse(s: []const u8) error{Bad}!u32 {
    if (s.len == 0) return error.Bad;
    return @intCast(s.len);
}
var failures: u32 = 0;
pub fn width(s: []const u8) u32 {
    if (parse(s)) |_| blk: {
        break :blk;
    } else |_| {
        failures += 1;
    }
    return 8;
}
