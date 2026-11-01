// warp-fast: a parameter's payload unwrapped by orelse into the field is a borrow.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, maybe: ?std.Io.File) void {
    s.file = maybe orelse return;
}
