// matrix: a pointer into the frame published to a global by an atomic store
var current: ?*u32 = null;
pub fn f() void {
    var x: u32 = 1;
    x += 1;
    @atomicStore(?*u32, &current, &x, .release);
}
