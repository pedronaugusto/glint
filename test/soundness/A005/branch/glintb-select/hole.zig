// glint-b: A005 branch (select): the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, k: u8) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    switch (k) {
        0 => gpa.free(buffer),
        else => {},
    }
    return Bytes.adopt(buffer, n);
}
