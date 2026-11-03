// std's streamRemaining reads a peer's stream to its end into a growing writer: it passes
// `.unlimited` inside std, and A012 knows a read with no limit only by the name holding
// "Unlimited" or a `.unlimited` written at the program's call
const std = @import("std");
pub fn f(stream: std.Io.net.Stream, io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    var buf: [256]u8 = undefined;
    var sr = stream.reader(io, &buf);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    _ = try sr.interface.streamRemaining(&aw.writer);
    return aw.toOwnedSlice();
}
