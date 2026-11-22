// A012 (opt-in): std's namespace an element of tuples joined by ++, its unbounded list made: a finding.
const aegis = @import("aegis");
const std = @import("std");
const both = .{std.mem} ++ .{std};
pub fn f() usize {
    var list: both[1].ArrayList(u8) = .empty;
    _ = &list;
    return list.items.len;
}
