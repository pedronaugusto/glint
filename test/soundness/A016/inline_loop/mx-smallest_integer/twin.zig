// matrix: each id's own type over the integer an inline loop picks
const std = @import("std");
const aegis = @import("aegis");
fn Smallest(comptime limit: comptime_int) type {
    inline for (.{ u16, u32, u64 }) |T| {
        if (std.math.maxInt(T) >= limit) return T;
    }
    unreachable;
}
const Raw = Smallest(1 << 20);
pub fn link(node_id: aegis.id.Id(enum { node }, Raw), edge_id: aegis.id.Id(enum { edge }, Raw)) void {
    _ = node_id;
    _ = edge_id;
}
