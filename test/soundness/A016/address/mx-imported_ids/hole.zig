// matrix: the ids' u32 named through another file's declarations
const ids = @import("ids.zig");
pub fn connect(node_id: ids.NodeId, edge_id: ids.EdgeId) void {
    _ = node_id;
    _ = edge_id;
}
