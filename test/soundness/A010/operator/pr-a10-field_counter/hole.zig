// precision A010 operator: a write before the steps sets the field to the peer's number, which a step up overflows
const std = @import("std");
const Scanner = struct {
    text: []const u8,
    depth: u64 = 0,
    fn scan(s: *Scanner, start: u64) !void {
        s.depth = start;
        for (s.text) |c| switch (c) {
            '{' => s.depth += 1,
            '}' => {
                if (s.depth == 0) return error.Unbalanced;
                s.depth -= 1;
            },
            else => {},
        };
    }
};
pub fn f(r: *std.Io.Reader) !bool {
    var s: Scanner = .{ .text = try r.take(try r.takeInt(u16, .little)) };
    try s.scan(try r.takeInt(u64, .little));
    return s.depth == 0;
}
