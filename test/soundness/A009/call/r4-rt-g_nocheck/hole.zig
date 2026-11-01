// review 4: rt/g_nocheck.zig
const std = @import("std");
pub const P = struct {
    table: [16]u8 = @splat(0),
    at: usize = 0,
    pub fn get(self: *P, reader: *std.Io.Reader) !u8 {
        self.at = try reader.takeByte();
        return self.table[self.at];
    }
};
