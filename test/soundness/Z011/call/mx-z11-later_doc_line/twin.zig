// matrix: Z011 call: a function whose doc's second line says it is not deprecated: a line counts
// only when it starts with the word, so the call is not reported
/// Runs the step the current way.
/// Not deprecated: this replaced `old`.
fn fresh() void {}
pub fn run() void {
    fresh();
}
