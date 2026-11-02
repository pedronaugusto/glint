// A field's byte stored from input through std.mem.asBytes of its record: Range reads the field as only its default, 0, and clears the index.
const std = @import("std");
const Header = extern struct { kind: u8 = 0 };
const names = [_][]const u8{ "a", "b" };
pub fn load(h: *Header, r: *std.Io.Reader) !void {
    std.mem.asBytes(h)[0] = try r.takeByte();
}
pub fn name(h: *const Header) []const u8 {
    return names[h.kind];
}
