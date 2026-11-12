// matrix: a slice of the caller's array put into a returned struct literal
const R = struct { s: []u8 };
pub fn f(buf: *[8]u8, n: usize) R {
    buf[0] = 1;
    return .{ .s = buf[0..n] };
}
