// matrix: Z011 conversion: a deprecated function called through a function pointer @ptrCast converts
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    const f: *const fn () void = @ptrCast(&old);
    f();
}
