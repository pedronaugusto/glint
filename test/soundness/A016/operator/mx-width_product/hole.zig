// matrix: the ids' integer made from a width computed by an operator
const Id = @Int(.unsigned, 16 * 2);
pub fn link(parent_id: Id, child_id: u32) void {
    _ = parent_id;
    _ = child_id;
}
