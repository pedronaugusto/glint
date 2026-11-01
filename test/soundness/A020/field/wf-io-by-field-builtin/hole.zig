// warp-fast: the bound is read from a reader @field names; the loop has no
// cancellation point.
const std = @import("std");
const Worker = struct { io: std.Io, r: *std.Io.Reader };
pub fn spin(w: *Worker) !u64 {
    const n = try @field(w, "r").takeInt(u64, .little);
    var t: u64 = 0;
    while (t != n) t +%= 1;
    return t;
}
