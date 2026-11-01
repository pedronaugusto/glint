// matrix: the ids' types destructured from one tuple in the function that makes the public type
fn Make() type {
    const NodeId, const EdgeId = .{ u32, u32 };
    return struct {
        pub fn connect(node_id: NodeId, edge_id: EdgeId) void {
            _ = node_id;
            _ = edge_id;
        }
    };
}
pub const Graph = Make();
