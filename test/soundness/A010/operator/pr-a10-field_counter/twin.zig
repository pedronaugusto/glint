// precision A010 operator: a struct's depth field stepped up and down once a pass over memory is at most its value at entry plus the passes, here none
const std = @import("std");
const Scanner = struct {
    text: []const u8,
    depth: usize = 0,
    fn scan(s: *Scanner) !void {
        s.depth = 0;
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
    try s.scan();
    return s.depth == 0;
}
