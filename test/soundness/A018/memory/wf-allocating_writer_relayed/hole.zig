// matrix: an error's name printed into an allocating writer, whose bytes are then written to the peer
const std = @import("std");
pub fn reply(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream, err: anyerror) !void {
    var listing: std.Io.Writer.Allocating = .init(gpa);
    defer listing.deinit();
    const out = &listing.writer;
    try out.print("failed: {s}\n", .{@errorName(err)});
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll(listing.written());
    try w.flush();
}
