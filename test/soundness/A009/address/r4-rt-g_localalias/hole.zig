// review 4: rt/g_localalias.zig
const std = @import("std");
pub const P = struct {
    table: [16]u8 = @splat(0),
    at: usize = 0,
    fn check(self: *P) !void {
        const q = self;
        if (self.at >= self.table.len) return error.Range;
        q.at = q.table.len;
    }
    pub fn get(self: *P, reader: *std.Io.Reader) !u8 {
        self.at = try reader.takeByte();
        try self.check();
        return self.table[self.at];
    }
};
