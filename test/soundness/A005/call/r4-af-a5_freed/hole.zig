// review 4: af/a5_freed.zig
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    gpa.free(buffer);
    return Bytes.adopt(buffer, n);
}
