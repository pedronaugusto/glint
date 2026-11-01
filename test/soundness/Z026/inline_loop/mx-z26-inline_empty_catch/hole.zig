// matrix: Z026 inline_loop: an inline loop over fallible functions, each error dropped by an empty catch
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() void {
    inline for (.{ fallible, fallible }) |f| f() catch {};
}
