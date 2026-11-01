// warp-fast: the Io is held by a struct reached through a pointer cast
// of the parameter: the function holds that Io as surely as a `*Worker` parameter's `w.io`.
const std = @import("std");
const Worker = struct { io: std.Io, r: *std.Io.Reader };
pub fn spin(raw: *align(@alignOf(Worker)) u8) !u64 {
    const w: *Worker = @ptrCast(raw);
    const n = try w.r.takeInt(u64, .little);
    var t: u64 = 0;
    while (t != n) t +%= 1;
    return t;
}
