// matrix: Z011 assignment: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    const f = fresh;
    f();
}
