// review 5: a20/c03_nested_field_io.zig
const std = @import("std");
const Ctx = struct { io: std.Io };
const Worker = struct {
    ctx: Ctx,
    count: u64 = 0,
    pub fn run(self: *Worker) void {
        while (true) self.count +%= 1;
    }
};
pub fn start(w: *Worker) void {
    w.run();
}
