// matrix: Z011 memory: the same, calling the fresh function
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run(slot: **const fn () void) void {
    @atomicStore(*const fn () void, slot, &fresh, .release);
    @atomicLoad(*const fn () void, slot, .acquire)();
}
