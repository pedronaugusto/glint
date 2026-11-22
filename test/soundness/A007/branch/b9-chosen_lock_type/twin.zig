// A007: a guard chosen by an if, aegis's either way, held by a field: none.
const aegis = @import("aegis");
const shared = false;
const Guard = if (shared) aegis.RwGuarded(u32) else aegis.BlockingGuarded(u32);
pub const Counter = struct { count: Guard = .init(0) };
