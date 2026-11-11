// matrix: Z011 branch: an if expression that chooses between two deprecated functions, called
/// Deprecated: use `fresh`.
fn old() void {}
/// Deprecated: use `fresh`.
fn older() void {}
fn fresh() void {}
pub fn run(c: bool) void {
    const f = if (c) &old else &older;
    f();
}
