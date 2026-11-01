// review 6: a03/h05_use_after_close.zig
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !u64 {
    const file = try dir.openFile(io, "a", .{});
    file.close(io);
    return (try file.stat(io)).size;
}
