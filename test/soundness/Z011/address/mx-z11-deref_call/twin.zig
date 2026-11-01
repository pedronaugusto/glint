// matrix: Z011 address: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    const p = &fresh;
    p.*();
}
