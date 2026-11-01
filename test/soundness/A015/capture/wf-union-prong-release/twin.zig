// warp-fast: the union field given only a parameter and read through a prong's capture, never released: a borrow
const std = @import("std");
const Res = union(enum) { file: std.Io.File, none };
const Stored = struct { res: Res, n: u32 };
pub fn store(s: *Stored, r: Res) void {
    s.res = r;
}
pub fn size(s: *Stored, io: std.Io) !u64 {
    return switch (s.res) {
        .file => |x| (try x.stat(io)).size,
        .none => 0,
    };
}
