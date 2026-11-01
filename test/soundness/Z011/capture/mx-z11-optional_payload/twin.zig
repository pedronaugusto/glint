// matrix: Z011 capture: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run(c: bool) void {
    const maybe: ?*const fn () void = if (c) &fresh else null;
    if (maybe) |f| f();
}
