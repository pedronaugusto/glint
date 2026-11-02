// Input copied into a record's bytes by @memcpy through std.mem.asBytes: its field indexes the program's table.
const std = @import("std");
const Header = extern struct { kind: u8 = 0 };
const names = [_][]const u8{ "a", "b" };
pub fn load(h: *Header, r: *std.Io.Reader) !void {
    @memcpy(std.mem.asBytes(h), try r.takeArray(1));
}
pub fn name(h: *const Header) []const u8 {
    return names[h.kind];
}
