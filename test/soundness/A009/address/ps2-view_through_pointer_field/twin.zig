// twin
const std = @import("std");
const Header = extern struct { kind: u8 = 0 };
const Conn = struct { h: *Header };
const names = [_][]const u8{ "a", "b" };
pub fn load(c: *Conn, r: *std.Io.Reader) !void {
    std.mem.asBytes(c.h)[0] = try r.takeByte();
}
pub fn name(h: *const Header) []const u8 {
    return names[h.kind & 1];
}
