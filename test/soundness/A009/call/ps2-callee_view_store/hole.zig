// The record's bytes handed to a helper that stores input through its slice parameter.
const std = @import("std");
const Header = extern struct { kind: u8 = 0 };
const names = [_][]const u8{ "a", "b" };
fn put(b: []u8, r: *std.Io.Reader) !void {
    b[0] = try r.takeByte();
}
pub fn load(h: *Header, r: *std.Io.Reader) !void {
    try put(std.mem.asBytes(h), r);
}
pub fn name(h: *const Header) []const u8 {
    return names[h.kind];
}
