// A007: a field holding aegis's guard, which holds the data: none.
const aegis = @import("aegis");
pub const Counter = struct { count: aegis.BlockingGuarded(u32) = .init(0) };
