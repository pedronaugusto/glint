// A018 in a build script: an error's name written to a network stream is a peer's.
const std = @import("std");
pub fn build(b: *std.Build) void {
    _ = b;
}
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.print("{s}\n", .{@errorName(err)});
    try w.flush();
}
