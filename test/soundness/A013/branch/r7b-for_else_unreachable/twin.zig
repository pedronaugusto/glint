// twin: the for's else returns an error
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    for (line, 0..) |b, i| {
        if (b == ':') break;
        _ = i;
    } else return error.NoColon;
    return 0;
}
