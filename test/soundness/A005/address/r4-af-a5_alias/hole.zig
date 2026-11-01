// review 4: af/a5_alias.zig
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, keep: *[]u8) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    keep.* = buffer;
    return Bytes.adopt(buffer, n);
}
