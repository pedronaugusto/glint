// matrix: Z011 conversion: a deprecated function called through @as
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    @as(*const fn () void, &old)();
}
