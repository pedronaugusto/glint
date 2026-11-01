// warp-fast: a union field given only a parameter, released through a switch prong's capture
const std = @import("std");
const Res = union(enum) { file: std.Io.File, none };
const Stored = struct { res: Res, n: u32 };
pub fn store(s: *Stored, r: Res) void {
    s.res = r;
}
pub fn close(s: *Stored, io: std.Io) void {
    switch (s.res) {
        .file => |x| x.close(io),
        .none => {},
    }
}
