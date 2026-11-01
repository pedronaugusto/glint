// matrix: Z011 compile_time: a deprecated function handed as a comptime parameter and called
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
fn twice(comptime f: fn () void) void {
    f();
    f();
}
pub fn run() void {
    twice(old);
}
