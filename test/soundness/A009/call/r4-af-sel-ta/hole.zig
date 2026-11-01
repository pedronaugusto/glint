// review 4: af/sel/ta.zig
const std = @import("std");
const tb = @import("tb.zig");
pub fn f(r: *std.Io.Reader, table: []const u8) !u8 {
    const i = try tb.get(r);
    return table[i];
}
