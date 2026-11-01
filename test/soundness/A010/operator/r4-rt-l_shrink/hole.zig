// review 4: rt/l_shrink.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendNTimes(gpa, 0, 400);
    const n: usize = try r.takeInt(u16, .little);
    list.shrinkRetainingCapacity(@min(n, 400));
    return list.items.len - 86;
}
