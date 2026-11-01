// review 6: a20/e05_io_array_field.zig
const std = @import("std");
const Pool = struct { ios: [2]std.Io };
pub fn spin(p: *const Pool, r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) t +%= i;
    _ = p;
    return t;
}
