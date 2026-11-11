// A013: unreachable at a function's end, after a loop that returns on a peer's byte: reached only when no byte is ':'
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    for (line, 0..) |b, i| {
        if (b == ':') return i;
    }
    unreachable;
}
