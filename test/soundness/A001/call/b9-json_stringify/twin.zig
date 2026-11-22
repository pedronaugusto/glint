// A001: the material a Secret exposes through its own API, written as JSON.
const aegis = @import("aegis");
const std = @import("std");
pub fn dump(w: *std.Io.Writer, s: *const aegis.Secret([4]u8)) !void {
    try std.json.Stringify.value(s.expose().*, .{}, w);
}
