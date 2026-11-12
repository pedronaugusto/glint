// matrix: the many-item pointer of a slice of the caller's array, returned
pub fn f(buf: *[4]u8) [*]u8 {
    buf[0] = 1;
    return buf[0..].ptr;
}
