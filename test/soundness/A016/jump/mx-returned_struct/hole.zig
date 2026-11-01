// matrix: a public generic's returned struct holds two usize indexes
pub fn Span(comptime T: type) type {
    return struct {
        items: []const T,
        first_index: usize,
        last_index: usize,
    };
}
