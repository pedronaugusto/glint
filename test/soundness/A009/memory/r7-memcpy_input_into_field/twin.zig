// Input copied into a buffer of its own by @memcpy; the record's field keeps its default.
const std = @import("std");
const Header = extern struct { kind: u8 = 0 };
const names = [_][]const u8{ "a", "b" };
pub fn load(buf: *[1]u8, r: *std.Io.Reader) !void {
    @memcpy(buf, try r.takeArray(1));
}
pub fn name(h: *const Header) []const u8 {
    return names[h.kind];
}
