// matrix: each id's own type over a labeled block's integer
const aegis = @import("aegis");
const Raw = blk: {
    if (@sizeOf(usize) < 8) break :blk u32;
    break :blk u64;
};
pub fn link(node_id: aegis.id.Id(enum { node }, Raw), edge_id: aegis.id.Id(enum { edge }, Raw)) void {
    _ = node_id;
    _ = edge_id;
}
