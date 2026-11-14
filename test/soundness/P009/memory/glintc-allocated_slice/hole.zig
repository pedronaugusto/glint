// P009: a slice of a local array, returned from a type function's method: the frame's memory.
pub fn Decoder(comptime Context: type) type {
    return struct {
        context: Context,
        pub fn values(self: @This(), n: usize) []u32 {
            _ = self;
            var held: [4]u32 = .{ 1, 2, 3, 4 };
            return held[0..n];
        }
    };
}
