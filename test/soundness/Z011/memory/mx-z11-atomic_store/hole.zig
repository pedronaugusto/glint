// matrix: Z011 memory: a deprecated function stored into a function-pointer slot by @atomicStore and called
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run(slot: **const fn () void) void {
    @atomicStore(*const fn () void, slot, &old, .release);
    @atomicLoad(*const fn () void, slot, .acquire)();
}
