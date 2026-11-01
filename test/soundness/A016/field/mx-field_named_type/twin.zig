// matrix: each id's own type named by `@field` of a namespace
const aegis = @import("aegis");
const Ids = struct {
    pub const node = aegis.id.Id(enum { node }, u32);
    pub const edge = aegis.id.Id(enum { edge }, u32);
};
pub fn connect(node_id: @field(Ids, "node"), edge_id: @field(Ids, "edge")) void {
    _ = node_id;
    _ = edge_id;
}
