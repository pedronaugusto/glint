// A012 (opt-in): std's namespace named by a destructure, its unbounded list made: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f() usize {
    const ns, _ = .{ std, @as(u8, 0) };
    var list: ns.ArrayList(u8) = .empty;
    _ = &list;
    return list.items.len;
}
