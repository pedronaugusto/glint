// The same, its result type a public declaration.
pub const Shown = struct { x: u8 };
fn makeShown() Shown {
    return .{ .x = 1 };
}
pub fn make() @TypeOf(makeShown()) {
    return makeShown();
}
