// matrix: a slice of a local pointer given the address of a local array, returned
pub fn f(n: u8) []u8 {
    var buf: [4]u8 = .{ n, n, n, n };
    buf[0] = 1;
    const pointer: [*]u8 = &buf;
    return pointer[0..2];
}
