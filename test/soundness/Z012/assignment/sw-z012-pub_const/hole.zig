// A public constant of a private type.
const Hidden = struct { x: u8 };
pub const default: Hidden = .{ .x = 1 };
