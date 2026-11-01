// matrix: each id's own type made by a call of a type function
const aegis = @import("aegis");
fn Index(comptime Tag: type) type {
    return aegis.id.Id(Tag, u32);
}
pub fn link(parent_index: Index(enum { parent }), child_index: Index(enum { child })) void {
    _ = parent_index;
    _ = child_index;
}
