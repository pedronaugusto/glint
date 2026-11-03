// warp-fast: a private struct of two u32 ids used only inside a public function's body.
const Edge = struct {
    source_id: u32,
    target_id: u32,
};
pub fn link(source: u32, target: u32) u32 {
    const edge: Edge = .{ .source_id = source, .target_id = target };
    return edge.source_id + edge.target_id;
}
