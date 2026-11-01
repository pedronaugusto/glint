// warp-fast: the same loop asks the Io @field reads on each pass.
const std = @import("std");
const Worker = struct { io: std.Io, r: *std.Io.Reader };
pub fn spin(w: *Worker) !u64 {
    const n = try @field(w, "r").takeInt(u64, .little);
    var t: u64 = 0;
    while (t != n) {
        try @field(w, "io").checkCancel();
        t +%= 1;
    }
    return t;
}
