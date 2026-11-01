// matrix: each id's own type out of a configured optional type, by `orelse` and `.?`
const aegis = @import("aegis");
const configured: ?type = aegis.id.Id(enum { node }, u32);
const NodeId = configured orelse usize;
pub fn link(node_id: NodeId, edge_id: aegis.id.Id(enum { edge }, u32)) void {
    _ = node_id;
    _ = edge_id;
}
