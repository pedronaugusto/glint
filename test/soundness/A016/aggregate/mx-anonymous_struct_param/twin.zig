// matrix: two distinct ids put together in a public signature's anonymous struct
const aegis = @import("aegis");
pub fn link(ends: struct { node_id: aegis.id.Id(enum { node }, u32), edge_id: aegis.id.Id(enum { edge }, u32) }) void {
    _ = ends;
}
