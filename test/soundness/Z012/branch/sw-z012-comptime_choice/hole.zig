// A private type chosen at comptime between two containers written in place: each is held by the choice, not a declaration.
const builtin = @import("builtin");
const Hidden = if (builtin.is_test) struct { x: u8 } else struct { y: u8 };
pub fn make() Hidden {
    return undefined;
}
