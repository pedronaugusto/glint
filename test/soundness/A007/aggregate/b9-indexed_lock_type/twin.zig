// A007: aegis's guard an element of a tuple, held by a field: none.
const aegis = @import("aegis");
const guards = .{aegis.BlockingGuarded(u32)};
pub const Counter = struct { count: guards[0] = .init(0) };
