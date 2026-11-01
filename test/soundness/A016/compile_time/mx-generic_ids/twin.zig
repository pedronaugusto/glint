// matrix: an id and a count of one comptime parameter's type
pub fn shift(comptime T: type, node_id: T, by: T) T {
    return node_id +% by;
}
