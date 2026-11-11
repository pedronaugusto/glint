// A005 deferred (errdefer after the take): an error exit follows the adoption, so the errdefer
// frees memory the owner holds; the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    errdefer gpa.free(buffer);
    const owned = try Bytes.adopt(buffer, n);
    if (n == 1) return error.Short;
    return owned;
}
