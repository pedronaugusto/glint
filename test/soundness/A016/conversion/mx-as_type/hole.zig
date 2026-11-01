// matrix: the ids' u32 passed through `@as(type, ...)`
const Id = @as(type, u32);
pub fn link(parent_id: Id, child_id: u32) void {
    _ = parent_id;
    _ = child_id;
}
