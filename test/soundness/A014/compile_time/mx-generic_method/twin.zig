// matrix: a method of a type a comptime function makes returns a slice of the caller's array
pub fn Buffer(comptime n: usize) type {
    return struct {
        pub fn fill(buf: *[n]u8, byte: u8) []u8 {
            buf.* = @splat(byte);
            return buf[0..];
        }
    };
}

/// A binding: the ruling's remedy for a public generic nothing else binds.
pub fn fill8(buf: *[8]u8) []u8 {
    return Buffer(8).fill(buf, 0);
}
