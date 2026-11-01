// matrix: Z011 aggregate: a deprecated function put in a struct literal and called through its field
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    const ops = .{ .run = &old };
    ops.run();
}
