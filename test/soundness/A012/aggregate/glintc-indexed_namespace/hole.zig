// A012 (opt-in): std's namespace an element of a tuple, its unbounded list made: a finding.
const aegis = @import("aegis");
const std = @import("std");
const kinds = .{std};
pub fn f() usize {
    var list: kinds[0].ArrayList(u8) = .empty;
    _ = &list;
    return list.items.len;
}
