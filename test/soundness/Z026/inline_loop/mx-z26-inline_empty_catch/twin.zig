// matrix: Z026 inline_loop: an inline loop over fallible functions, each error counted
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run() void {
    inline for (.{ fallible, fallible }) |f| f() catch {
        failures += 1;
    };
}
