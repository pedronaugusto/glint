// matrix: the ids' integer made by a call of a type function
fn Index(comptime bits: u16) type {
    return @Int(.unsigned, bits);
}
pub fn link(parent_index: Index(32), child_index: Index(32)) void {
    _ = parent_index;
    _ = child_index;
}
