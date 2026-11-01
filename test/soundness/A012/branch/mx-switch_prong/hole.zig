// matrix: a switch expression gives input in one prong, the size
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, kind: enum { small, sized }) ![]u8 {
    const n: u32 = switch (kind) {
        .small => 16,
        .sized => try r.takeInt(u32, .little),
    };
    return gpa.alloc(u8, n);
}
