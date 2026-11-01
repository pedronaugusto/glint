// review 6: a20/e09_io_global_struct.zig
const std = @import("std");
const App = struct { io: std.Io, n: u64 };
var app: App = undefined;
// The Io a global struct holds, used in the function after the loop.
pub fn spin(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) t +%= i;
    try app.io.checkCancel();
    return t;
}
