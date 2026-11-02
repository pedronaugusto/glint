// The same, its type declared public.
const builtin = @import("builtin");
pub const Hidden = if (builtin.is_test) struct { x: u8 } else struct { y: u8 };
pub fn make() Hidden {
    return undefined;
}
