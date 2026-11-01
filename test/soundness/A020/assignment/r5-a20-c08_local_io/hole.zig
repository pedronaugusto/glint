// review 5: a20/c08_local_io.zig
const std = @import("std");
const Worker = struct {
    io: std.Io,
    count: u64 = 0,
};
pub fn run(w: Worker) void {
    const io = w.io;
    _ = io;
    var n: u64 = 0;
    while (true) n +%= 1;
}
