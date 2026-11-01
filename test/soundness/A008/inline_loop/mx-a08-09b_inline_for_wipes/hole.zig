// matrix A008: hand wipes unrolled over two buffers.
const std = @import("std");
pub fn wipeAll(a: []u8, b: []u8) void {
    inline for (.{ a, b }) |buffer| std.crypto.secureZero(u8, buffer);
}
