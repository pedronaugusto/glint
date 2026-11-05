// A public type function whose result type is spelled through an alias of `type`, bound with File: its field holds an owner its file releases.
const std = @import("std");
const File = std.Io.File;
const Type = type;
pub fn Box(comptime T: type) Type {
    return struct {
        held: T,
        pub fn deinit(self: *@This(), io: std.Io) void {
            self.held.close(io);
        }
    };
}
pub fn f(dir: std.Io.Dir, io: std.Io) !Box(File) {
    return .{ .held = try dir.openFile(io, "a", .{}) };
}
