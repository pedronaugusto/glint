// matrix: the ids' integer chosen by an `if` on the target's pointer size
const Id = if (@sizeOf(usize) == 8) u64 else u32;
pub fn link(parent_id: Id, child_id: Id) void {
    _ = parent_id;
    _ = child_id;
}
