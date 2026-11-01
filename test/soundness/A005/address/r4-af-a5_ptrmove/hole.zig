// review 4: af/a5_ptrmove.zig
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    var buffer = try gpa.alloc(u8, n);
    buffer.ptr += 1;
    return Bytes.adopt(buffer, n - 1);
}
