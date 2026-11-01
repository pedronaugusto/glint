// matrix: Z011 destructure: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    const f, const g = .{ fresh, fresh };
    f();
    g();
}
