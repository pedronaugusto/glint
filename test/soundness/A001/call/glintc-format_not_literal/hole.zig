// A001: a Secret placed by a format no literal writes, the caller's: what it places glint does
// not read, so the call is refused, never passed (a `{any}` caller walks the material).
const aegis = @import("aegis");
const std = @import("std");
pub fn show(w: *std.Io.Writer, comptime fmt: []const u8, s: aegis.Secret([32]u8)) !void {
    try w.print(fmt, .{s});
}
