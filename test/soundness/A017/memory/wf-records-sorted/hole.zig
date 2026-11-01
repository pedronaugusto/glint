// warp-fast: records sorted by std, the first reset by a literal under a switch on its state.
const std = @import("std");
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    id: u32 = 0,
    pub fn start(j: *Job) void {
        j.state = .running;
    }
};
fn earlier(_: void, a: Job, b: Job) bool {
    return a.id < b.id;
}
pub fn order(jobs: []Job) void {
    std.mem.sort(Job, jobs, {}, earlier);
    switch (jobs[0].state) {
        .running => jobs[0] = .{ .state = .idle, .id = jobs[0].id },
        else => {},
    }
}
