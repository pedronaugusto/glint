// A capture of the guard a pointer a call gives points at: it stays in s.guard, the copy duplicates it.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const State = struct {
    guard: ?L.Guard,
    fn slot(s: *State) *?L.Guard { return &s.guard; }
};
pub fn f(s: *State) void {
    if (s.slot().*) |g| {
        var copy = g;
        copy.deinit();
    }
}
