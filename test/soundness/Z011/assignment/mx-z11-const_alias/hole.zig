// matrix: Z011 assignment: a deprecated function called through a local alias
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    const f = old;
    f();
}
