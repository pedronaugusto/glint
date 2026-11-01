// matrix: Z011 branch: a deprecated function chosen by an if expression and called
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run(c: bool) void {
    const f = if (c) &old else &fresh;
    f();
}
