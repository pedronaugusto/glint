// twin: the function's end after the loop returns an error
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    for (line, 0..) |b, i| {
        if (b == ':') return i;
    }
    return error.NoColon;
}
