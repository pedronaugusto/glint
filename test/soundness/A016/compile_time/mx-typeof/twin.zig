// matrix: each id's own type, one of them `@TypeOf` a constant
const aegis = @import("aegis");
const NodeId = aegis.id.Id(enum { node }, u32);
const root_id: NodeId = .fromRaw(0);
pub fn link(node_id: @TypeOf(root_id), edge_id: aegis.id.Id(enum { edge }, u32)) void {
    _ = node_id;
    _ = edge_id;
}
