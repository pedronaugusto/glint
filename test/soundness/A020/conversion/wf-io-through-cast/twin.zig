// warp-fast: the same loop asks the cast struct's Io on each pass.
const std = @import("std");
const Worker = struct { io: std.Io, r: *std.Io.Reader };
pub fn spin(raw: *align(@alignOf(Worker)) u8) !u64 {
    const w: *Worker = @ptrCast(raw);
    const n = try w.r.takeInt(u64, .little);
    var t: u64 = 0;
    while (t != n) {
        try w.io.checkCancel();
        t +%= 1;
    }
    return t;
}
