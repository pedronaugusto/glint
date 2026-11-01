// matrix: Z011 field: a deprecated function called through @field naming it
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    @field(@This(), "old")();
}
