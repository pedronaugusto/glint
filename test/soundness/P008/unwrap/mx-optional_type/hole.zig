// matrix: the ids' u32 out of a configured optional type, by `orelse` and `.?`
const configured: ?type = u32;
const Id = configured orelse usize;
pub fn link(parent_id: Id, child_id: configured.?) void {
    _ = parent_id;
    _ = child_id;
}
