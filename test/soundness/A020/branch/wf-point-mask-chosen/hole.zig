// warp-fast: the mask is input: a peer sending all ones leaves only the first
// pass reaching the point.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const n = try r.takeInt(u64, .little);
    const m = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (t != n) : (i += 1) {
        if (i & m == 0) try io.checkCancel();
        t +%= 1;
    }
    return t;
}
