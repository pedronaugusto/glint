// P014: the reported form
const std = @import("std");
pub fn warn(io: std.Io, line: []const u8) !void {
    const stream = std.Io.File.stderr();
    var buffer: [256]u8 = undefined;
    var err = stream.writer(io, &buffer);
    try err.interface.writeAll(line);
    try err.interface.flush();
}
