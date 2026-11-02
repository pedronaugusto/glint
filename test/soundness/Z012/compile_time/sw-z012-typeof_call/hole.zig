// A result typed by what a private function returns, inline.
fn makeHidden() struct { x: u8 } {
    return .{ .x = 1 };
}
pub fn make() @TypeOf(makeHidden()) {
    return makeHidden();
}
