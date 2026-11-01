// review 6: a20/e07_method_self_ptr_ptr.zig
const std = @import("std");
const W = struct {
    io: std.Io,
    // The receiver by value of a struct that holds an Io through a pointer field to it.
    inner: *const W2,
};
const W2 = struct { io: std.Io };
pub fn spin(w: struct { ctx: *const W2 }, r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) t +%= i;
    _ = w;
    return t;
}
