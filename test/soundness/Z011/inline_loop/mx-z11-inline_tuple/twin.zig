// matrix: Z011 inline_loop: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run() void {
    inline for (.{ fresh, fresh }) |f| f();
}
