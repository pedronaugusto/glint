// Input stored as a record literal of another type through a pointer cast of the record: its field indexes the table.
const std = @import("std");
const Header = extern struct { kind: u8 = 0 };
const Wire = extern struct { tag: u8 };
const names = [_][]const u8{ "a", "b" };
pub fn load(h: *Header, r: *std.Io.Reader) !void {
    const w: *Wire = @ptrCast(h);
    w.* = .{ .tag = try r.takeByte() };
}
pub fn name(h: *const Header) []const u8 {
    return names[h.kind];
}
