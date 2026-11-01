// review 5: a20/c05_optional_field_io.zig
const std = @import("std");
const Worker = struct {
    io: ?std.Io,
    count: u64 = 0,
    pub fn run(self: *Worker) void {
        while (true) self.count +%= 1;
    }
};
pub fn start(w: *Worker) void {
    w.run();
}
