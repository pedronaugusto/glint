const builtin = @import("builtin");
const Hidden = struct { x: u8 };
/// A type in a test build, a Hidden value in every other.
pub const default = if (builtin.is_test) u8 else Hidden{ .x = 1 };
