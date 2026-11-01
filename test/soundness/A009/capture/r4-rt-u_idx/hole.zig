// review 4: rt/u_idx.zig
const std = @import("std");
const V = union(enum) { at: u32, none };
pub fn f(r: *std.Io.Reader, table: []const u8) !u8 {
    const v: V = .{ .at = try r.takeInt(u32, .little) };
    switch (v) {
        .at => |i| return table[i],
        .none => return 0,
    }
}
