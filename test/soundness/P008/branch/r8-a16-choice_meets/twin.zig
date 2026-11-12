// warp-fast: an id whose integer a build chooses never meets a u16 id: no build picks u16.
const Id = if (@sizeOf(usize) == 8) u64 else u32;
pub fn link(parent_id: Id, child_id: u16) void {
    _ = parent_id;
    _ = child_id;
}
