// A field's byte stored with a constant through std.mem.asBytes of its record: the index stays in the table.
const std = @import("std");
const Header = extern struct { kind: u8 = 0 };
const names = [_][]const u8{ "a", "b" };
pub fn load(h: *Header) void {
    std.mem.asBytes(h)[0] = 1;
}
pub fn name(h: *const Header) []const u8 {
    return names[h.kind];
}
