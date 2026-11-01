// matrix: Z011 deferred: a deprecated function called by a defer
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    defer old();
}
