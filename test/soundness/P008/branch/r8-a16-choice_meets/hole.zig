// warp-fast: an id whose integer a build chooses meets a u32 id in the build that picks u32.
const Id = if (@sizeOf(usize) == 8) u64 else u32;
pub fn link(parent_id: Id, child_id: u32) void {
    _ = parent_id;
    _ = child_id;
}
