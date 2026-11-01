// review 6: a05/s03_free_ptr_number.zig
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
fn release(gpa: std.mem.Allocator, p: [*]u8, len: usize) usize {
    gpa.free(p[0..len]);
    return len;
}
// Its pointer handed to a call that frees it and gives back a number.
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    _ = release(gpa, buffer.ptr, buffer.len);
    return Bytes.adopt(buffer, n);
}
