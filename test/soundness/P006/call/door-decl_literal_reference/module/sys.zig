const std = @import("std");

const Op = struct {
    run: *const fn (std.Io.File, std.Io) std.Io.File.SyncError!void,

    const direct: Op = .{ .run = std.Io.File.sync };
};

pub fn flush(file: std.Io.File, io: std.Io) !void {
    try Op.direct.run(file, io);
}

pub fn other(file: std.Io.File, io: std.Io) !void {
    const op: Op = .direct;
    try op.run(file, io);
}
