// review 7 A007: a tuple type written in place holds a raw std.Io.Mutex by value (typed by what a dependency's function gives): a tuple's fields are no declarations, so none is judged.
const std = @import("std");
const dep = @import("dep.zig");
const Pair = struct { @TypeOf(dep.make()), u32 };
pub fn run(io: std.Io) void {
    var p: Pair = .{ dep.make(), 0 };
    p[0].lockUncancelable(io);
    p[1] += 1;
    p[0].unlock(io);
}
