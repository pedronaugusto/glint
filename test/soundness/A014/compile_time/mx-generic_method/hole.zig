// matrix: a method of a type a comptime function makes returns a slice of its local array
pub fn Buffer(comptime n: usize) type {
    return struct {
        pub fn fill(byte: u8) []u8 {
            var buf: [n]u8 = @splat(byte);
            buf[0] = 1;
            return buf[0..];
        }
    };
}
