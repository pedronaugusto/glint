// A013: a for's else is reached only when no byte of a peer's line breaks the loop: unreachable there is input's to choose
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    for (line, 0..) |b, i| {
        if (b == ':') break;
        _ = i;
    } else unreachable;
    return 0;
}
