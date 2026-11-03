// A capture of a labeled block's value, a place: the guard stays in s.guard.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const State = struct { guard: ?L.Guard };
pub fn f(s: *State) void {
    if (blk: {
        break :blk s.guard;
    }) |g| {
        var copy = g;
        copy.deinit();
    }
}
