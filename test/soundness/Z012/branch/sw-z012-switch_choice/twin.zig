// The same, its type declared public.
const builtin = @import("builtin");
pub const Hidden = switch (builtin.mode) {
    .debug => struct { x: u8 },
    else => struct { x: u16 },
};
pub fn make() Hidden {
    return undefined;
}
