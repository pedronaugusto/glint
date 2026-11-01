// matrix: a private struct of two distinct ids made public by a re-export of its name
const aegis = @import("aegis");
const Edge = struct {
    source_id: aegis.id.Id(enum { node }, u32),
    target_id: aegis.id.Id(enum { port }, u32),
};
pub const Link = Edge;
