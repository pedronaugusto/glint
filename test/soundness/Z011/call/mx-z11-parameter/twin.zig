// matrix: Z011 call: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
fn apply(f: *const fn () void) void {
    f();
}
pub fn run() void {
    apply(&fresh);
}
