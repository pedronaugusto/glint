// A012 (opt-in): std's namespace reached through a pointer to it, its unbounded list made: a finding.
const aegis = @import("aegis");
const std = @import("std");
const ns = &std;
pub fn f() usize {
    var list: ns.*.ArrayList(u8) = .empty;
    _ = &list;
    return list.items.len;
}
