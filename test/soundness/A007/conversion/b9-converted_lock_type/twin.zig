// A007: aegis's guard converted to a type by @as, held by a field: none.
const aegis = @import("aegis");
pub const Counter = struct { count: @as(type, aegis.BlockingGuarded(u32)) = .init(0) };
