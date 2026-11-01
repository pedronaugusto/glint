// matrix: the machine's type is a comptime parameter of the generic that holds it
const aegis = @import("aegis");
const Phase = enum { idle, running, done };
const Event = enum { start, finish, reset };
const Life = aegis.state.Machine(Phase, Event, .{ .initial = .idle, .edges = &.{
    .{ .from = .idle, .on = .start, .to = .running },
    .{ .from = .running, .on = .finish, .to = .done },
    .{ .from = .done, .on = .reset, .to = .idle },
} });
fn Holder(comptime M: type) type {
    return struct {
        const Self = @This();
        life: M.Runtime(void) = .init({}),
        pub fn reset(s: *Self) !void {
            _ = try s.life.step(.reset);
        }
        pub fn step(s: *Self) !void {
            switch (s.life.current()) {
                .idle => _ = try s.life.step(.start),
                .running => _ = try s.life.step(.finish),
                .done => {},
            }
        }
    };
}
pub const Job = Holder(Life);
