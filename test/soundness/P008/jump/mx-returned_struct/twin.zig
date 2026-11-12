// matrix: a public generic's returned struct holds an index and a count of its own type
const aegis = @import("aegis");
pub fn Span(comptime T: type) type {
    return struct {
        items: []const T,
        first_index: aegis.id.Id(enum { item }, usize),
        len: usize,
    };
}

/// A binding: the ruling's remedy for a public generic nothing else binds.
pub fn length(span: Span(u8)) usize {
    return span.len;
}
