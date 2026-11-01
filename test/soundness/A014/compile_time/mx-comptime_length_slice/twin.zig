// matrix: a slice of the caller's array to a length the program fixes as it compiles
pub fn head(comptime n: usize, buf: *[8]u8) []const u8 {
    buf[0] = 1;
    const out = buf[0..n];
    return out;
}
