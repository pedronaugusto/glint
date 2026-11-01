// matrix: Z011 aggregate: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run(i: usize) void {
    const table = [_]*const fn () void{ &fresh, &fresh };
    table[i]();
}
