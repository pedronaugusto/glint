// warp-fast: records sorted by std under a switch on one's state: std moves whole records it is handed.
const std = @import("std");
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    id: u32 = 0,
    pub fn start(j: *Job) void {
        j.state = .running;
    }
    pub fn finish(j: *Job) void {
        j.state = .done;
    }
};
fn earlier(_: void, a: Job, b: Job) bool {
    return a.id < b.id;
}
pub fn order(jobs: []Job) void {
    switch (jobs[0].state) {
        .done => std.mem.sort(Job, jobs, {}, earlier),
        else => {},
    }
}
