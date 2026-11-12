// matrix: a pointer into the caller's memory published to a global by an atomic store
var current: ?*u32 = null;
pub fn f(into: *u32) void {
    into.* += 1;
    @atomicStore(?*u32, &current, into, .release);
}
