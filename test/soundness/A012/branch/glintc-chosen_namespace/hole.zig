// A012 (opt-in): std's namespace chosen by an if, its unbounded list made: a finding.
const aegis = @import("aegis");
const std = @import("std");
const wide = false;
const ns = if (wide) std else std;
pub fn f() usize {
    var list: ns.ArrayList(u8) = .empty;
    _ = &list;
    return list.items.len;
}
