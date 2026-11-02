// The same alias, its result type public.
pub const Hidden = struct { x: u8 };
fn makeHidden() Hidden {
    return .{ .x = 1 };
}
pub const make = makeHidden;
