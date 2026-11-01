// matrix: the ids' integer is a labeled block's result
const Id = blk: {
    if (@sizeOf(usize) < 8) break :blk u32;
    break :blk u64;
};
pub fn link(parent_id: Id, child_id: Id) void {
    _ = parent_id;
    _ = child_id;
}
