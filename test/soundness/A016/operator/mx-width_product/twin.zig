// matrix: each id's own type over a width computed by an operator
const aegis = @import("aegis");
const Raw = @Int(.unsigned, 16 * 2);
pub fn link(node_id: aegis.id.Id(enum { node }, Raw), edge_id: aegis.id.Id(enum { edge }, Raw)) void {
    _ = node_id;
    _ = edge_id;
}
