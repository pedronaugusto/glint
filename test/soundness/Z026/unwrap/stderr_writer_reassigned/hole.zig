// Z026: an empty catch on a write through a writer made for standard error, then reassigned
const std = @import("std");
pub fn report(io: std.Io, buf: []u8) void {
    var w = std.Io.File.stderr().writer(io, buf);
    w = std.Io.File.stdout().writer(io, buf);
    w.interface.writeAll("result\n") catch {};
}
