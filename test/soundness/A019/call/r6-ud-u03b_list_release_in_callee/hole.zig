// review 6: ud/u03b_list_release_in_callee.zig
const std = @import("std");
fn drop(s: *std.ArrayList(u8), gpa: std.mem.Allocator) void {
    s.deinit(gpa);
}
pub fn f(gpa: std.mem.Allocator) !usize {
    var s: std.ArrayList(u8) = .empty;
    try s.append(gpa, 1);
    drop(&s, gpa);
    return s.items.len;
}
