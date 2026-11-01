// matrix: a private struct of two u32 ids made public by a re-export of its name
const Edge = struct {
    source_id: u32,
    target_id: u32,
};
pub const Link = Edge;
