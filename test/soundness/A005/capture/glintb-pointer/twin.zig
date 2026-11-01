// glint-b: A005 capture (pointer): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, keep: *?usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    if (keep.*) |*slot| slot.* = buffer.len;
    return Bytes.adopt(buffer, n);
}
