// matrix: Z011 deferred: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    defer fresh();
}
