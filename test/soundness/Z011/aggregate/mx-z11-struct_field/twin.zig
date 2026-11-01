// matrix: Z011 aggregate: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    const ops = .{ .run = &fresh };
    ops.run();
}
