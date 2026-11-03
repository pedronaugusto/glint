// pre-sweep-2 A007: aegis's bounded.Array holds its elements by value (`storage: [N]T`); its
// element, a dependency's record, holds std.Io.Mutex. A007 reads any instance aegis declares as
// aegis's own internals (heldSync's inLibrary), so the locks it holds are never seen.
const std = @import("std");
const aegis = @import("aegis");
const dep = @import("dep.zig");
pub const Pool = struct {
    slots: aegis.bounded.Array(dep.Shared, 4) = .init,
};
pub fn bump(pool: *Pool, io: std.Io) !u32 {
    const first = try pool.slots.at(0);
    first.lock.lockUncancelable(io);
    defer first.lock.unlock(io);
    first.n += 1;
    return first.n;
}
