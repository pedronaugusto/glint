// review 4: rt/l_resize.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    const n: usize = try r.takeInt(u16, .little);
    try list.resize(gpa, n);
    return list.items.len - 86;
}
