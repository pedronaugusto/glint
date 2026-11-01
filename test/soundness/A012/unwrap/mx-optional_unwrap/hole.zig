// matrix: an optional holding input unwrapped by .? sizes the allocation
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var maybe: ?u32 = null;
    maybe = try r.takeInt(u32, .little);
    return gpa.alloc(u8, maybe.?);
}
