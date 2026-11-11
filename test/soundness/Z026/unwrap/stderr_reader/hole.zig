// Z026: an empty handler on a read from standard error
const std = @import("std");
pub fn poll(io: std.Io, buf: []u8) void {
    var r = std.Io.File.stderr().reader(io, buf);
    _ = r.interface.takeByte() catch {};
}
