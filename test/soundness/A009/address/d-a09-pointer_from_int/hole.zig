// matrix A009 address: input stored at an address, read back through another pointer made from it
const std = @import("std");
pub fn f(r: *std.Io.Reader, table: *const [16]u8, addr: usize) !u8 {
    const p: *usize = @ptrFromInt(addr);
    p.* = try r.takeInt(u32, .little);
    const q: *const usize = @ptrFromInt(addr);
    return table[q.*];
}
