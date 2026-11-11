// A013: unreachable after a loop that leaves its labeled block on a peer's byte: reached only when no byte is ':'
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    const at = blk: {
        for (line, 0..) |b, i| {
            if (b == ':') break :blk i;
        }
        unreachable;
    };
    return at;
}
