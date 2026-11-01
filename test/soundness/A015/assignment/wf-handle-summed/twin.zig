// warp-fast: a field's handle summed into a local that is only returned releases nothing: a borrow
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn sum(s: *Stored) i64 {
    var t: i64 = 0;
    t += s.file.handle;
    return t;
}
