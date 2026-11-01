// matrix: a pointer into the frame chosen by an if expression, stored where it outlives the call
var last: ?*u32 = null;
pub fn f(given: ?*u32) void {
    var own: u32 = 0;
    own += 1;
    last = if (given) |p| p else &own;
}
