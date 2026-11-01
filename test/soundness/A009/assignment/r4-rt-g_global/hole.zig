// review 4: rt/g_global.zig
const std = @import("std");
pub const P = struct {
    table: [16]u8 = @splat(0),
    at: usize = 0,
    fn check(self: *P) !void {
        if (self.at >= self.table.len) return error.Range;
        bump();
    }
};
var shared: P = .{};
fn bump() void {
    shared.at += 1;
}
pub fn get(reader: *std.Io.Reader) !u8 {
    shared.at = try reader.takeByte();
    try shared.check();
    return shared.table[shared.at];
}
