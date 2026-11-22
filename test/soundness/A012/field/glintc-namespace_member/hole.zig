// A012 (opt-in): std's namespace a container's member, its unbounded list made: a finding.
const aegis = @import("aegis");
const std = @import("std");
const Kit = struct {
    const ns = std;
};
pub fn f() usize {
    var list: Kit.ns.ArrayList(u8) = .empty;
    _ = &list;
    return list.items.len;
}
