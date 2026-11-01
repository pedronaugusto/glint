// review 6: a20/e00_param_base.zig
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) t +%= i;
    _ = io;
    return t;
}
