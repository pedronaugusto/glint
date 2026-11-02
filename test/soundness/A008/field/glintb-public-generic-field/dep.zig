// A dependency's public generic: a box that holds what its type parameter names by value.
pub fn Box(comptime T: type) type {
    return struct { value: T };
}
