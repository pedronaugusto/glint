// A001: a format no literal writes placing only what no governed type is: nothing to read.
const aegis = @import("aegis");
const std = @import("std");
pub fn show(w: *std.Io.Writer, comptime fmt: []const u8, n: u32) !void {
    try w.print(fmt, .{n});
}
