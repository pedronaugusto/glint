// matrix: each id's own type bound by an `if` capture of a configured optional type
const aegis = @import("aegis");
const Config = struct { node: ?type = null, edge: ?type = null };
const config: Config = .{ .node = aegis.id.Id(enum { node }, u32), .edge = aegis.id.Id(enum { edge }, u32) };
const NodeId = if (config.node) |T| T else @compileError("no node id");
const EdgeId = if (config.edge) |T| T else @compileError("no edge id");
pub fn link(node_id: NodeId, edge_id: EdgeId) void {
    _ = node_id;
    _ = edge_id;
}
