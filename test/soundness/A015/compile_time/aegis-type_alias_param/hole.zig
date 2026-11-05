// A public generic whose type parameter is spelled through an alias of `type`: bound with File and handed the file just opened, it returns an owner handed over.
const std = @import("std");
const File = std.Io.File;
const Type = type;
pub fn pass(comptime U: Type, v: U) U {
    return v;
}
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const h = pass(File, try dir.openFile(io, "a", .{}));
    h.close(io);
}
