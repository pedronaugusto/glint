// matrix: Z011 jump: a deprecated function carried out of a labeled block and called
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    const f = blk: {
        break :blk &old;
    };
    f();
}
