// matrix: Z011 branch: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run(c: bool) void {
    const f = if (c) &fresh else &fresh;
    f();
}
