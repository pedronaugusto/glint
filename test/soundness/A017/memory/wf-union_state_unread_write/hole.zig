// warp-fast: a tagged union given whole values in one function and written through its bytes in
// another (a write whose value is not read), moved under a switch on it and switched on: whether
// that write gives it a literal choice is not known, so it is undecided, never a value (A017's
// ruling, 11-06).
const std = @import("std");
pub const Worker = struct {
    state: union(enum) { idle, busy: u32, done } = .idle,
    pub fn start(w: *Worker, given: @FieldType(Worker, "state")) void {
        switch (w.state) {
            .idle => w.state = given,
            else => {},
        }
    }
    pub fn clear(w: *Worker) void {
        if (w.state == .done) @memset(std.mem.asBytes(&w.state), 0);
    }
    pub fn report(w: *const Worker) u32 {
        return switch (w.state) {
            .idle => 0,
            .busy => |n| n,
            .done => 1,
        };
    }
};
