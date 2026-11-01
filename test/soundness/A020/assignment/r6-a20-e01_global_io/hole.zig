// review 6: a20/e01_global_io.zig
const std = @import("std");
var g_io: std.Io = undefined;
pub fn init(io: std.Io) void {
    g_io = io;
}
// The function reaches an Io through a global: it is given one, and never cancels.
pub fn spin(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) t +%= i;
    _ = g_io;
    return t;
}
