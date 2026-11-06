// warp-fast: a tagged union whose writes give it its tags as literals (`.idle`, `.{ .busy = n }`),
// written in two functions, moved under a switch on it and switched on: a state set kept by hand
// (A017's ruling, 11-06).
pub const Worker = struct {
    state: union(enum) { idle, busy: u32, done } = .idle,
    pub fn start(w: *Worker, n: u32) void {
        switch (w.state) {
            .idle => w.state = .{ .busy = n },
            else => {},
        }
    }
    pub fn finish(w: *Worker) void {
        if (w.state == .busy) w.state = .done;
    }
    pub fn report(w: *const Worker) u32 {
        return switch (w.state) {
            .idle => 0,
            .busy => |n| n,
            .done => 1,
        };
    }
};
