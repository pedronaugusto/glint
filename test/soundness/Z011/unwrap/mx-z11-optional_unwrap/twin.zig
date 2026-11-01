// matrix: Z011 unwrap: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    const maybe: ?*const fn () void = &fresh;
    maybe.?();
}
