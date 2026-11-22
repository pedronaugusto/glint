// A012 (opt-in): std's namespace unwrapped from an optional by .?, its unbounded list made: a finding.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = std;
pub fn f() usize {
    var list: held.?.ArrayList(u8) = .empty;
    _ = &list;
    return list.items.len;
}
