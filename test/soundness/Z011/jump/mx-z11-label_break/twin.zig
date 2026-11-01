// matrix: Z011 jump: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    const f = blk: {
        break :blk &fresh;
    };
    f();
}
