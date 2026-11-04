// warp-fast: the same generic returns the reader's cause on ReadFailed
const std = @import("std");
pub fn first(h: anytype, io: std.Io) !u8 {
    var buf: [64]u8 = undefined;
    var r = h.reader(io, &buf);
    return r.interface.takeByte() catch |e| switch (e) {
        error.ReadFailed => r.err.?,
        else => |other| other,
    };
}

/// A binding: the ruling's remedy for a public generic nothing else binds.
pub fn firstOfFile(file: std.Io.File, io: std.Io) !u8 {
    return first(file, io);
}
