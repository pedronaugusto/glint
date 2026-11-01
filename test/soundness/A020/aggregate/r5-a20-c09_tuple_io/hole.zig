// review 5: a20/c09_tuple_io.zig
const std = @import("std");
pub fn spin(ctx: struct { std.Io, u8 }) void {
    _ = ctx;
    var n: u64 = 0;
    while (true) n +%= 1;
}
