// matrix: a for loop's pointer capture into a local array stored where it outlives the call
var last: ?*u8 = null;
pub fn f(n: u8) void {
    var buf: [4]u8 = .{ n, n, n, n };
    for (&buf) |*b| last = b;
}
