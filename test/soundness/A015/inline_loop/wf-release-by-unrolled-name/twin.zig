// warp-fast: an inline for that only reads the field's handle releases nothing: a borrow.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn sum(s: *Stored) i64 {
    var t: i64 = 0;
    inline for (.{"file"}) |name| t += @field(s, name).handle;
    return t;
}
