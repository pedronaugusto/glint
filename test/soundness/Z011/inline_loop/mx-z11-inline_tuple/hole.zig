// matrix: Z011 inline_loop: an inline loop over a tuple of deprecated functions, each called
/// Deprecated: use `fresh`.
fn old() void {}
/// Deprecated: use `fresh`.
fn older() void {}
fn fresh() void {}
pub fn run() void {
    inline for (.{ old, older }) |f| f();
}
