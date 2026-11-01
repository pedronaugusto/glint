// matrix: Z011 inline_loop: a deprecated function called by an inline loop over a tuple of functions
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    inline for (.{ old, fresh }) |f| f();
}
