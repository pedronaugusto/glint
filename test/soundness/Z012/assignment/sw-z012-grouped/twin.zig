// The same type in parentheses, public: callers name it.
pub const Hidden = (struct { x: u8 });
pub fn make() Hidden {
    return .{ .x = 1 };
}
