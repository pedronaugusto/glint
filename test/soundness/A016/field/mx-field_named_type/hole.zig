// matrix: the ids' u32 named by `@field` of a namespace
const Ids = struct {
    pub const node = u32;
    pub const edge = u32;
};
pub fn connect(node_id: @field(Ids, "node"), edge_id: @field(Ids, "edge")) void {
    _ = node_id;
    _ = edge_id;
}
