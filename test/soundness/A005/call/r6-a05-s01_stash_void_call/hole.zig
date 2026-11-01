// review 6: a05/s01_stash_void_call.zig
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
var kept: []u8 = &.{};
fn stash(p: []u8) void {
    kept = p;
}
// A call that returns nothing keeps the allocation elsewhere before the owner adopts it.
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    stash(buffer);
    return Bytes.adopt(buffer, n);
}
