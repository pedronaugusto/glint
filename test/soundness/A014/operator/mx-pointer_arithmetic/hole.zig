// matrix: a many-item pointer into a local array moved by addition, returned
pub fn f(n: u8) [*]u8 {
    var buf: [4]u8 = .{ n, n, n, n };
    buf[0] = 1;
    const p: [*]u8 = &buf;
    return p + 1;
}
