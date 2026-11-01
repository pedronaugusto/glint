// review 5: a20/c11_alias_io.zig
const std = @import("std");
const Io = std.Io;
const Handle = Io;
pub fn spin(io: Handle) void {
    _ = io;
    var n: u64 = 0;
    while (true) n +%= 1;
}
