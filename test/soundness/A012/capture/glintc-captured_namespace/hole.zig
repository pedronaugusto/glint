// A012 (opt-in): std's namespace captured from an optional, its unbounded list made: a finding.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = std;
pub fn f() usize {
    if (held) |ns| {
        var list: ns.ArrayList(u8) = .empty;
        _ = &list;
        return list.items.len;
    }
    return 0;
}
