// matrix: a slice of a local array to a length the program fixes as it compiles, through a comptime parameter
pub fn head(comptime n: usize, byte: u8) []const u8 {
    var buf: [8]u8 = @splat(byte);
    buf[0] = 1;
    const out = buf[0..n];
    return out;
}
