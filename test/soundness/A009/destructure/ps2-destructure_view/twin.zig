// twin
const std = @import("std");
const Header = extern struct { kind: u8 = 0, pad: u8 = 0 };
const names = [_][]const u8{ "a", "b" };
pub fn load(h: *Header, r: *std.Io.Reader) !void {
    const b = std.mem.asBytes(h);
    b[0], b[1] = .{ try r.takeByte(), 0 };
}
pub fn name(h: *const Header) []const u8 {
    return names[h.kind & 1];
}
