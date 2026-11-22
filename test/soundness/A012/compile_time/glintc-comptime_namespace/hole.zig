// A012 (opt-in): std's namespace a comptime expression's value, its unbounded list made: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f() usize {
    const ns = comptime std;
    var list: ns.ArrayList(u8) = .empty;
    _ = &list;
    return list.items.len;
}
