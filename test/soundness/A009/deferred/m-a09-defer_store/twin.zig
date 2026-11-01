// matrix A009 deferred: a defer overwrites the input index with one in range at the block's exit
const std = @import("std");
pub fn f(r: *std.Io.Reader, table: *const [16]u8) !u8 {
    var i: u8 = 0;
    {
        defer i = 3;
        i = try r.takeByte();
    }
    return table[i];
}
