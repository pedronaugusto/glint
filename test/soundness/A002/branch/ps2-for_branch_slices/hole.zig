// A loop over a choice of two arrays' elements: each guard stays where it is, the copy duplicates it.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const State = struct { a: [2]L.Guard, b: [2]L.Guard };
pub fn f(s: *State, first: bool) void {
    for (if (first) s.a else s.b) |g| {
        var copy = g;
        copy.deinit();
    }
}
