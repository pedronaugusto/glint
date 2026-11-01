// matrix: a for loop's pointer capture into the caller's array stored where it outlives the call
var last: ?*u8 = null;
pub fn f(buf: *[4]u8) void {
    for (buf) |*b| last = b;
}
