// matrix: an id and a count of one comptime parameter's type
pub fn shift(comptime T: type, node_id: T, by: T) T {
    return node_id +% by;
}

/// A binding: the ruling's remedy for a public generic nothing else binds.
pub fn shift32(node_id: u32, by: u32) u32 {
    return shift(u32, node_id, by);
}
