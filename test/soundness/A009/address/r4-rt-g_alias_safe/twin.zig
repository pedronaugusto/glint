// review 4: rt/g_alias_safe.zig
const std = @import("std");
pub const P = struct {
    table: [16]u8 = @splat(0),
    at: usize = 0,
    fn check(self: *P, other: *P) !void {
        if (self.at >= self.table.len) return error.Range;
        _ = other;
    }
    pub fn get(self: *P, reader: *std.Io.Reader) !u8 {
        self.at = try reader.takeByte();
        try self.check(self);
        return self.table[self.at];
    }
};
