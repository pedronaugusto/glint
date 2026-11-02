// A private type a comptime switch chooses.
const builtin = @import("builtin");
const Hidden = switch (builtin.mode) {
    .Debug => struct { x: u8 },
    else => struct { x: u16 },
};
pub fn make() Hidden {
    return undefined;
}
