// P006 call: a decl literal (`.direct` where the place's type declares `direct`) is a reference
// to that declaration: the raw sync it holds is reached outside the door.
const std = @import("std");
const module = @import("module");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try module.other(file, io);
}
