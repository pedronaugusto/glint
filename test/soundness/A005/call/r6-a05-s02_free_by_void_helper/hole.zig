// review 6: a05/s02_free_by_void_helper.zig
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
fn drop(gpa: std.mem.Allocator, p: []u8) void {
    gpa.free(p);
}
// A helper frees it, returning nothing: the owner adopts freed memory.
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    drop(gpa, buffer);
    return Bytes.adopt(buffer, n);
}
