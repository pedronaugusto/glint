// matrix: the state's type is a comptime parameter of the generic that holds it
const Phase = enum { idle, running, done };
fn Holder(comptime State: type) type {
    return struct {
        const Self = @This();
        state: State = .idle,
        pub fn reset(s: *Self) void {
            s.state = .idle;
        }
        pub fn step(s: *Self) void {
            switch (s.state) {
                .idle => s.state = .running,
                .running => s.state = .done,
                .done => {},
            }
        }
    };
}
pub const Job = Holder(Phase);
