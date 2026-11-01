// glint-b: A005 capture (pointer): the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, keep: *?[]u8) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    if (keep.*) |*slot| slot.* = buffer;
    return Bytes.adopt(buffer, n);
}
