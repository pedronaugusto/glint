// glint-b: a bool that says the optional is held, read the wrong way round: the `.?` meets null
const std = @import("std");
pub fn f(r: *std.Io.Reader, workers: []const bool) !u8 {
    const b = try r.takeByte();
    const got: ?u8 = if (b > 3) b else null;
    var refused = got != null;
    for (workers) |w| refused = refused or w;
    if (!refused) return got.?;
    return 0;
}
