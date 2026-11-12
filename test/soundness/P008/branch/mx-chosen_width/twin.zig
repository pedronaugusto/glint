// matrix: each id's own type over an integer chosen by an `if` on the target's pointer size
const aegis = @import("aegis");
const Raw = if (@sizeOf(usize) == 8) u64 else u32;
pub fn link(node_id: aegis.id.Id(enum { node }, Raw), edge_id: aegis.id.Id(enum { edge }, Raw)) void {
    _ = node_id;
    _ = edge_id;
}
