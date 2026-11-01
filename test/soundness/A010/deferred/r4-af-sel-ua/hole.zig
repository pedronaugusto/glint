// review 4: af/sel/ua.zig
const std = @import("std");
const tb = @import("tb.zig");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !u32 {
    const n = try tb.get(r);
    const m = n * 4096;
    const mem = try gpa.alloc(u8, m);
    defer gpa.free(mem);
    return m;
}
