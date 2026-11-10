const std = @import("std");

const Each = struct { file: std.Io.File, io: std.Io };

fn raw(each: Each, a: u8, b: u8) bool {
    each.file.sync(each.io) catch return false;
    return a < b;
}

pub fn flush(file: std.Io.File, io: std.Io) !void {
    var order = [_]u8{ 2, 1 };
    std.mem.sort(u8, &order, Each{ .file = file, .io = io }, raw);
}
