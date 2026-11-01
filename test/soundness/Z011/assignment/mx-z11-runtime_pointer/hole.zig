// matrix: Z011 assignment: a deprecated function called through a runtime function-pointer variable
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    var f: *const fn () void = &old;
    _ = &f;
    f();
}
