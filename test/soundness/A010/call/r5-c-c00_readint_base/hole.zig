// review 5: c/c00_readint_base.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const bytes = try r.takeArray(8);
    const x = std.mem.readInt(u64, bytes, .little);
    return x * 2;
}
