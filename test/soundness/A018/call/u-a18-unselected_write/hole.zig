// matrix A018 call: an error's name passed to a function of a file the run does not select, which writes it to a peer
const std = @import("std");
const w = @import("w.zig");
pub fn f(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    try w.send(io, stream, @errorName(err));
}
