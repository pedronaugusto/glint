// matrix A018 call: the program's own text passed to that function, an error beside it
const std = @import("std");
const w = @import("w.zig");
pub fn f(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    if (err == error.OutOfMemory) try w.send(io, stream, "busy");
}
