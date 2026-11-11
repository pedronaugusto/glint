// A type parameter is the caller's own type.
pub fn first(comptime T: type, items: []const T) ?T {
    return if (items.len == 0) null else items[0];
}
