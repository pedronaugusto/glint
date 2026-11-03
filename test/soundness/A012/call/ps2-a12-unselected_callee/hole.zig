// a size from input handed to a function of a file the run does not select (dep.zig, or a
// dependency's module), which allocates by it: the call is the program's own (no site here),
// and the file holding the allocation is never judged
const std = @import("std");
const dep = @import("dep.zig");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u32, .little);
    return dep.grab(gpa, n);
}
