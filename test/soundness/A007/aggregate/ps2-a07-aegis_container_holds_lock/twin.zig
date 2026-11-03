// pre-sweep-2 A007 twin: the same array of a record holding a counter.
const std = @import("std");
const aegis = @import("aegis");
const dep = @import("dep.zig");
pub const Pool = struct {
    slots: aegis.bounded.Array(dep.Plain, 4) = .init,
};
pub fn bump(pool: *Pool) !u32 {
    const first = try pool.slots.at(0);
    first.n += 1;
    return first.n;
}
