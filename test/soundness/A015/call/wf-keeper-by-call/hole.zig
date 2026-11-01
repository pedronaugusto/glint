// warp-fast: an opened file handed through @call to another file's keeper, which keeps it in a field it releases
const std = @import("std");
const Keeper = @import("before.zig").Keeper;
pub fn give(k: *Keeper, dir: std.Io.Dir, io: std.Io) !void {
    @call(.auto, Keeper.keep, .{ k, try dir.openFile(io, "a", .{}) });
}
