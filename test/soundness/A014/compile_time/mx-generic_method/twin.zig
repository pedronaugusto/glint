// matrix: a method of a type a comptime function makes returns a slice of the caller's array
pub fn Buffer(comptime n: usize) type {
    return struct {
        pub fn fill(buf: *[n]u8, byte: u8) []u8 {
            buf.* = @splat(byte);
            return buf[0..];
        }
    };
}
