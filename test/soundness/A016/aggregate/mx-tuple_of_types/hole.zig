// matrix: the ids' types taken out of a tuple of types
const Ids = .{ u32, u32 };
pub fn link(parent_id: Ids[0], child_id: Ids[1]) void {
    _ = parent_id;
    _ = child_id;
}
