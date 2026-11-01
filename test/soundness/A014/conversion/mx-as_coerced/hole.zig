// matrix: a pointer into the frame coerced by @as to a const pointer, stored where it outlives the call
var last: ?*const u32 = null;
pub fn f() void {
    var x: u32 = 1;
    x += 1;
    last = @as(*const u32, &x);
}
