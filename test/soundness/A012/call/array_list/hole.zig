// A012 (opt-in): a std list that grows without a stated limit.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(gpa: std.mem.Allocator) !std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 1);
    return list;
}
