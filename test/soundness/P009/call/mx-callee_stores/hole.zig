// matrix: a pointer into the frame handed to a callee that stores it where it outlives the call
var registered: ?*u32 = null;
fn register(p: *u32) void {
    registered = p;
}
pub fn f() void {
    var x: u32 = 1;
    x += 1;
    register(&x);
}
