// warp-fast: a private struct of two u32 ids a public function takes: callers outside build it.
const Edge = struct {
    source_id: u32,
    target_id: u32,
};
pub fn link(edge: Edge) u32 {
    return edge.source_id + edge.target_id;
}
