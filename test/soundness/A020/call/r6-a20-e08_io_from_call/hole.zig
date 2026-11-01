// review 6: a20/e08_io_from_call.zig
const std = @import("std");
var g_io: std.Io = undefined;
fn io() std.Io {
    return g_io;
}
// The Io reached through a call of the program's: the loop may be in a task it cancels.
pub fn spin(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) t +%= i;
    try io().checkCancel();
    return t;
}
