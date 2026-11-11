// matrix: Z011 branch: an if expression that chooses between a deprecated function and a current
// one: one deprecated alternative of several is not certain, so the call is not reported
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run(c: bool) void {
    const f = if (c) &old else &fresh;
    f();
}
