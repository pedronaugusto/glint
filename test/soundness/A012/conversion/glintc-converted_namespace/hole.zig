// A012 (opt-in): std's namespace converted to a type by @as, its unbounded list made: a finding.
const aegis = @import("aegis");
const std = @import("std");
const ns = @as(type, std);
pub fn f() usize {
    var list: ns.ArrayList(u8) = .empty;
    _ = &list;
    return list.items.len;
}
