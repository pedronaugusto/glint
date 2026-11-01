// matrix: each id's own type taken out of a tuple of types
const aegis = @import("aegis");
const Ids = .{ aegis.id.Id(enum { node }, u32), aegis.id.Id(enum { edge }, u32) };
pub fn link(node_id: Ids[0], edge_id: Ids[1]) void {
    _ = node_id;
    _ = edge_id;
}
