// matrix: two node ids whose u32 reaches the signature through a chain of aliases
const Raw = u32;
const NodeId = Raw;
pub fn link(parent_id: NodeId, child_id: Raw) void {
    _ = parent_id;
    _ = child_id;
}
