// glint-b: a bool that says the optional is null, or a worker refused: not refused, it holds a value
const std = @import("std");
pub fn f(r: *std.Io.Reader, workers: []const bool) !u8 {
    const b = try r.takeByte();
    const got: ?u8 = if (b > 3) b else null;
    var refused = got == null;
    for (workers) |w| refused = refused or w;
    if (!refused) return got.?;
    return 0;
}
