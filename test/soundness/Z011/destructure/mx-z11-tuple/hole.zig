// matrix: Z011 destructure: a deprecated function destructured out of a tuple and called
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    const f, const g = .{ old, fresh };
    f();
    g();
}
