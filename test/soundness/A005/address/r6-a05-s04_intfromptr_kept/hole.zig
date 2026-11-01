// review 6: a05/s04_intfromptr_kept.zig
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
var where: usize = 0;
// Its address kept as a number, made into a pointer again later.
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    where = @intFromPtr(buffer.ptr);
    return Bytes.adopt(buffer, n);
}
