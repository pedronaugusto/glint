// review 6: a20/e30_point_debug_only.zig
const std = @import("std");
const builtin = @import("builtin");
// The point is compiled only in Debug: a release build's loop has none.
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        if (builtin.mode == .debug) try io.checkCancel();
        t +%= i;
    }
    return t;
}
