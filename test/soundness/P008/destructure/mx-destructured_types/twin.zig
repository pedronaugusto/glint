// matrix: each id's own type destructured from one tuple in the function that makes the public type
const aegis = @import("aegis");
fn Make() type {
    const NodeId, const EdgeId = .{ aegis.id.Id(enum { node }, u32), aegis.id.Id(enum { edge }, u32) };
    return struct {
        pub fn connect(node_id: NodeId, edge_id: EdgeId) void {
            _ = node_id;
            _ = edge_id;
        }
    };
}
pub const Graph = Make();
