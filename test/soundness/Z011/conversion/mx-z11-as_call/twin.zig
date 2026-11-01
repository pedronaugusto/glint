// matrix: Z011 conversion: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    @as(*const fn () void, &fresh)();
}
