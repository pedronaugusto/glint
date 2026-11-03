// Input read by std's reader straight into the record's bytes.
const std = @import("std");
const Header = extern struct { kind: u8 = 0 };
const names = [_][]const u8{ "a", "b" };
pub fn load(h: *Header, r: *std.Io.Reader) !void {
    try r.readSliceAll(std.mem.asBytes(h));
}
pub fn name(h: *const Header) []const u8 {
    return names[h.kind];
}
