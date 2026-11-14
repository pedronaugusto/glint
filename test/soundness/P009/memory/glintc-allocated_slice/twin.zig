// P009: what an allocator made through a generic context, whose type the reading does not
// resolve: a slice of it, or an element's address, points into the heap, not the frame (strand's
// decoder, 8h).
pub fn Decoder(comptime Context: type) type {
    return struct {
        context: Context,
        pub fn values(self: @This(), n: usize) ![]u32 {
            var held = try self.context.alloc(u32, n);
            held[0] = 1;
            return held[0..n];
        }
        pub fn first(self: @This()) !*u32 {
            const inner = try self.context.alloc(u32, 1);
            inner[0] = 1;
            return &inner[0];
        }
    };
}
