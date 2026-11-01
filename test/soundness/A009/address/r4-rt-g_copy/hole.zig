// review 4: rt/g_copy.zig
const std = @import("std");
pub const P = struct {
    table: [16]u8 = @splat(0),
    at: usize = 0,
    fn check(self: P) !void {
        if (self.at >= self.table.len) return error.Range;
    }
    pub fn get(self: *P, reader: *std.Io.Reader) !u8 {
        const before = self.*;
        self.at = try reader.takeByte();
        try before.check();
        return self.table[self.at];
    }
};
