// A012: the same list inside the seam the project declares for it is no finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(gpa: std.mem.Allocator) !std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 1);
    return list;
}
