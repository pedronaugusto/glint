// matrix: a pointer into the caller's memory handed to a callee that stores it
var registered: ?*u32 = null;
fn register(p: *u32) void {
    registered = p;
}
pub fn f(into: *u32) void {
    into.* += 1;
    register(into);
}
