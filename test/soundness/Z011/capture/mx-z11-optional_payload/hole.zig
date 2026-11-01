// matrix: Z011 capture: a deprecated function called as the payload an if captures from an optional pointer
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run(c: bool) void {
    const maybe: ?*const fn () void = if (c) &old else null;
    if (maybe) |f| f();
}
