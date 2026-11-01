// matrix: Z011 unwrap: a deprecated function called through .? of an optional pointer
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    const maybe: ?*const fn () void = &old;
    maybe.?();
}
