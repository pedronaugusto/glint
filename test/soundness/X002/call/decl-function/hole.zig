// replaces .decl: a call of the replaced function, resolved by its declaration, is a finding
// outside the declaring package.
const std = @import("std");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}
