// matrix A009 address: a constant stored at the address
const std = @import("std");
pub fn f(r: *std.Io.Reader, table: *const [16]u8, addr: usize) !u8 {
    const p: *usize = @ptrFromInt(addr);
    p.* = 3;
    _ = try r.takeInt(u32, .little);
    const q: *const usize = @ptrFromInt(addr);
    return table[q.*];
}
