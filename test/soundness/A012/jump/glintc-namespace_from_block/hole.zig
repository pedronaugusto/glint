// A012 (opt-in): std's namespace a labeled block's result, its unbounded list made: a finding.
const aegis = @import("aegis");
const std = @import("std");
const ns = blk: {
    break :blk std;
};
pub fn f() usize {
    var list: ns.ArrayList(u8) = .empty;
    _ = &list;
    return list.items.len;
}
