// A capture of a choice of two places: the guard stays in s.a or s.b, the copy duplicates it.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const State = struct { a: ?L.Guard, b: ?L.Guard };
pub fn f(s: *State, first: bool) void {
    if (if (first) s.a else s.b) |g| {
        var copy = g;
        copy.deinit();
    }
}
