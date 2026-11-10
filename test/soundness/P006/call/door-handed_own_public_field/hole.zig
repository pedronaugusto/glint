// P006 call: the same hand to the package's own function, which stores it in a public field,
// leaves the helper where code outside the door calls it.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.hooks().run(file, io);
}
