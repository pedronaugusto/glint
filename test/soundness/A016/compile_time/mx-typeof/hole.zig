// matrix: the ids' integer is `@TypeOf` a u32 constant
const root_id: u32 = 0;
pub fn link(parent_id: @TypeOf(root_id), child_id: @TypeOf(root_id)) void {
    _ = parent_id;
    _ = child_id;
}
