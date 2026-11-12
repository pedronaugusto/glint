// matrix: a many-item pointer into the caller's array moved by addition, returned
pub fn f(buf: *[4]u8) [*]u8 {
    buf[0] = 1;
    const p: [*]u8 = buf;
    return p + 1;
}
