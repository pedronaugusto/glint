// A001: a Secret written as ZON, std's serializer reading every field by reflection.
const aegis = @import("aegis");
const std = @import("std");
pub fn dump(w: *std.Io.Writer, s: aegis.Secret([4]u8)) !void {
    try std.zon.Serializer.serialize(s, .{}, w);
}
