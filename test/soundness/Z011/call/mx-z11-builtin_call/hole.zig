// matrix: Z011 call: a deprecated function called by @call
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    @call(.auto, old, .{});
}
