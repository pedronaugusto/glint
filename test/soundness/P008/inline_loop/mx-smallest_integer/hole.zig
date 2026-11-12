// matrix: the ids' integer picked by an inline loop over candidate widths
const std = @import("std");
fn Smallest(comptime limit: comptime_int) type {
    inline for (.{ u16, u32, u64 }) |T| {
        if (std.math.maxInt(T) >= limit) return T;
    }
    unreachable;
}
const Id = Smallest(1 << 20);
pub fn link(parent_id: Id, child_id: Id) void {
    _ = parent_id;
    _ = child_id;
}
