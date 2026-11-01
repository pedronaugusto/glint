// warp-fast: the keeper, another file's type, which keeps a file in a field it releases
const std = @import("std");
pub const Keeper = struct {
    f: std.Io.File,
    n: u32,
    pub fn keep(k: *Keeper, f: std.Io.File) void {
        k.f = f;
    }
    pub fn count(k: *Keeper, n: u32) void {
        k.n = n;
    }
    pub fn deinit(k: *Keeper, io: std.Io) void {
        k.f.close(io);
    }
};
