// matrix: Z011 call: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    @call(.auto, fresh, .{});
}
