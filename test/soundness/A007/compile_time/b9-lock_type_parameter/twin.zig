// A007: a type function given aegis's guard, which holds the data: none.
const aegis = @import("aegis");
fn Held(comptime Guard: type) type {
    return struct { count: Guard = .init(0) };
}
pub const Counter = Held(aegis.BlockingGuarded(u32));
