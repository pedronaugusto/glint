// warp-fast: the same union given only whole values from elsewhere: a value, no state set (A017's
// ruling, 11-06).
pub const Worker = struct {
    state: union(enum) { idle, busy: u32, done } = .idle,
    pub fn start(w: *Worker, given: @FieldType(Worker, "state")) void {
        switch (w.state) {
            .idle => w.state = given,
            else => {},
        }
    }
    pub fn finish(w: *Worker, given: @FieldType(Worker, "state")) void {
        if (w.state == .busy) w.state = given;
    }
    pub fn report(w: *const Worker) u32 {
        return switch (w.state) {
            .idle => 0,
            .busy => |n| n,
            .done => 1,
        };
    }
};
