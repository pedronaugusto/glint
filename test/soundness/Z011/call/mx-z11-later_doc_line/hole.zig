// matrix: Z011 call: a function whose doc's second line marks it deprecated, called directly
/// Runs the step the old way.
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    old();
}
