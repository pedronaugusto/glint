// matrix: a defer writes the failing error's name to the log and public text to the peer
const std = @import("std");
fn work(r: *std.Io.Reader) !void {
    _ = try r.takeByte();
}
pub fn serve(io: std.Io, stream: std.Io.net.Stream, r: *std.Io.Reader, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    var failure: ?anyerror = null;
    defer if (failure) |e| {
        log.print("{s}\n", .{@errorName(e)}) catch {};
        w.writeAll("internal error\n") catch {};
        w.flush() catch {};
    };
    work(r) catch |e| {
        failure = e;
        return e;
    };
}
