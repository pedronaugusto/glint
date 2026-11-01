// matrix: Z011 address: a deprecated function called through a pointer to it
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    const p = &old;
    p();
}
