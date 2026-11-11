// matrix: Z011 assignment: a current function called through an alias whose own doc marks it deprecated
fn fresh() void {}
/// Deprecated: call `fresh`.
const old = fresh;
pub fn run() void {
    old();
}
