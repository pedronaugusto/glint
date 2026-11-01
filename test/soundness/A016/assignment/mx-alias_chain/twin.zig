// matrix: each id's own type reaches the signature through a chain of aliases
const aegis = @import("aegis");
const RawNode = aegis.id.Id(enum { node }, u32);
const NodeId = RawNode;
const EdgeId = aegis.id.Id(enum { edge }, u32);
pub fn link(node_id: NodeId, edge_id: EdgeId) void {
    _ = node_id;
    _ = edge_id;
}
