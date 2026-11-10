// P006 call: the same helper stored in a field is a value whoever holds the field calls: its
// raw call is reached outside the door.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.hook().run(file, io);
}
