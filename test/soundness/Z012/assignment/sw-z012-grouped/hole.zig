// A private type written in parentheses: its container's parent is no declaration, so no private holder is found.
const Hidden = (struct { x: u8 });
pub fn make() Hidden {
    return .{ .x = 1 };
}
