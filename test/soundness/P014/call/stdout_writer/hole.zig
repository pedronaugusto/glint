// P014: the reported form
const std = @import("std");
pub fn say(io: std.Io, line: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    try out.interface.writeAll(line);
    try out.interface.flush();
}
