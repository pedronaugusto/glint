// matrix: Z011 aggregate: a deprecated function put in an array of function pointers and called by index
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run(i: usize) void {
    const table = [_]*const fn () void{ &old, &old };
    table[i]();
}
