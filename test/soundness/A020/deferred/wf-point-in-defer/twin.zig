// warp-fast: a defer in the pass's own block runs at the end of every
// pass: the point it asks is reached on each pass.
const std = @import("std");
pub fn spin(io: std.Io, n: u64) u64 {
    var t: u64 = 0;
    var cancelled = false;
    while (t != n and !cancelled) {
        defer io.checkCancel() catch {
            cancelled = true;
        };
        t +%= 1;
    }
    return t;
}
