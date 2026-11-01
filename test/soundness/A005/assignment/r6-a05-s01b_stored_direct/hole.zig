// review 6: a05/s01b_stored_direct.zig
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
var kept: []u8 = &.{};
// Twin: the same store written in place.
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    kept = buffer;
    return Bytes.adopt(buffer, n);
}
