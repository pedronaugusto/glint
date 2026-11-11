// matrix: Z011 assignment: the same alias with no deprecation in its doc
fn fresh() void {}
/// Another name for `fresh`.
const old = fresh;
pub fn run() void {
    old();
}
