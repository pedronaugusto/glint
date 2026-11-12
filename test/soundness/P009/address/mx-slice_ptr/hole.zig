// matrix: the many-item pointer of a slice of a local array, returned
pub fn f(n: u8) [*]u8 {
    var buf: [4]u8 = .{ n, n, n, n };
    buf[0] = 1;
    return buf[0..].ptr;
}
