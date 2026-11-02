// A capture of each guard a slice the call lends holds: the guards stay in `s`, so the copy
// duplicates a live guard and both are released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const State = struct {
    guards: [2]L.Guard,
    fn held(s: *State) []L.Guard {
        return s.guards[0..];
    }
};
pub fn f(s: *State) void {
    for (s.held()) |g| {
        var copy = g;
        copy.deinit();
    }
}
