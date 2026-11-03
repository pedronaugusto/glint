// A capture of what a call's pointer reaches, through `orelse`: it stays in s.guard.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const State = struct {
    guard: ?L.Guard,
    spare: ?L.Guard,
    fn slot(s: *State) *?L.Guard { return &s.guard; }
};
pub fn f(s: *State) void {
    if (s.slot().* orelse s.spare) |g| {
        var copy = g;
        copy.deinit();
    }
}
