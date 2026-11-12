// matrix: two ids of one comptime parameter's type, an integer at every call
pub fn link(comptime T: type, parent_id: T, child_id: T) void {
    _ = parent_id;
    _ = child_id;
}
pub fn linkNodes(parent_id: u16, child: u16) void {
    link(u16, parent_id, child);
}
