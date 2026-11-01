// matrix: a slice of a local array put into a returned struct literal
const R = struct { s: []u8 };
pub fn f(n: usize) R {
    var buf: [8]u8 = @splat(0);
    buf[0] = 1;
    return .{ .s = buf[0..n] };
}
