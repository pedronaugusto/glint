// matrix: Z011 call: a deprecated function handed to a callee that calls it
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
fn apply(f: *const fn () void) void {
    f();
}
pub fn run() void {
    apply(&old);
}
