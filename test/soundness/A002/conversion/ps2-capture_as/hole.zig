// A capture of a place through @as: the guard stays in s.guard.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const State = struct { guard: ?L.Guard };
pub fn f(s: *State) void {
    if (@as(?L.Guard, s.guard)) |g| {
        var copy = g;
        copy.deinit();
    }
}
