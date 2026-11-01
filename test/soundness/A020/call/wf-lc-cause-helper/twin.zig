// warp-fast: the helper returns the reader's cause on a cancel, so each read is a cancellation point
const std = @import("std");
const Lines = struct {
    source: *std.Io.File.Reader,
    io: std.Io,
    fn fault(self: *Lines) error{ ReadFailed, Canceled } {
        const err = self.source.err orelse return error.ReadFailed;
        return switch (err) {
            error.Canceled => error.Canceled,
            else => error.ReadFailed,
        };
    }
    fn fill(self: *Lines) error{ ReadFailed, Canceled, EndOfStream }!u8 {
        return self.source.interface.takeByte() catch |err| switch (err) {
            error.ReadFailed => return self.fault(),
            error.EndOfStream => return error.EndOfStream,
        };
    }
    pub fn skip(self: *Lines) !void {
        while (true) {
            if (try self.fill() == '\n') return;
        }
    }
};
