// glint-b: A005 branch (select): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, k: u8) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    switch (k) {
        0 => buffer[0] = 0,
        else => {},
    }
    return Bytes.adopt(buffer, n);
}
