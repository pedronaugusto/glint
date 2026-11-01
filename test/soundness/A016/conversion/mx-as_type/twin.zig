// matrix: each id's own type passed through `@as(type, ...)`
const aegis = @import("aegis");
const NodeId = @as(type, aegis.id.Id(enum { node }, u32));
pub fn link(node_id: NodeId, edge_id: aegis.id.Id(enum { edge }, u32)) void {
    _ = node_id;
    _ = edge_id;
}
