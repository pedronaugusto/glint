// A private type given through @as(type, ...).
const Hidden = @as(type, struct { x: u8 });
pub fn make() Hidden {
    return .{ .x = 1 };
}
