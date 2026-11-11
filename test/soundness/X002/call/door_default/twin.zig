// replaces without .door: the whole declaring package may use the target (module.zig's
// syncFile calls it); a consumer calling the answer is no finding.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.syncFile(file, io);
}
