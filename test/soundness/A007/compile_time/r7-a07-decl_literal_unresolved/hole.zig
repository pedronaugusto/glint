// review 7 A007: a local whose type does not resolve (a dependency picks it from a table: std.Io.Mutex), given the decl literal `.init`: read as an enum literal, its declaration is cleared.
const std = @import("std");
const dep = @import("dep.zig");
pub fn run(io: std.Io) void {
    var m: dep.Pick(0) = .init;
    m.lockUncancelable(io);
    m.unlock(io);
}
