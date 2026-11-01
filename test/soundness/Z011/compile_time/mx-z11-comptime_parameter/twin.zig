// matrix: Z011 compile_time: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
fn twice(comptime f: fn () void) void {
    f();
    f();
}
pub fn run() void {
    twice(fresh);
}
