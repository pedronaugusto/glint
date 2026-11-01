// matrix: a public callback's signature takes two distinct ids
const aegis = @import("aegis");
pub const Hooks = struct {
    linked: *const fn (node_id: aegis.id.Id(enum { node }, u32), edge_id: aegis.id.Id(enum { edge }, u32)) void,
};
