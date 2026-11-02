// The same, its type declared public.
pub const Hidden = struct { x: u8 };
pub fn make() @field(@This(), "Hidden") {
    return .{ .x = 1 };
}
