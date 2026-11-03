// the same read with a stated limit
const std = @import("std");
pub fn f(stream: std.Io.net.Stream, io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    var buf: [256]u8 = undefined;
    var sr = stream.reader(io, &buf);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    _ = try sr.interface.stream(&aw.writer, .limited(4096));
    return aw.toOwnedSlice();
}
