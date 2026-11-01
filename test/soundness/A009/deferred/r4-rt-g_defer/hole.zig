// review 4: rt/g_defer.zig
const std = @import("std");
pub const P = struct {
    table: [16]u8 = @splat(0),
    at: usize = 0,
    fn check(self: *P) !void {
        defer self.at = self.table.len;
        if (self.at >= self.table.len) return error.Range;
    }
    pub fn get(self: *P, reader: *std.Io.Reader) !u8 {
        self.at = try reader.takeByte();
        try self.check();
        return self.table[self.at];
    }
};
