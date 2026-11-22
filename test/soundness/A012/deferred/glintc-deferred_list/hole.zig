// A012 (opt-in): a std list made and freed at the scope's end: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(gpa: std.mem.Allocator) !usize {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    return list.items.len;
}
