// warp-fast: a loop whose only read maps its cause through a helper that turns a cancel into ReadFailed: no cancellation point, and the cancel is lost
const std = @import("std");
const Lines = struct {
    source: *std.Io.File.Reader,
    io: std.Io,
    fn fault(self: *Lines) error{ReadFailed} {
        _ = self.source.err;
        return error.ReadFailed;
    }
    fn fill(self: *Lines) error{ ReadFailed, EndOfStream }!u8 {
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
