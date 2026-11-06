// An import of the case's, not selected: a table indexed by a container-level variable.
pub var at: u8 = 0;
const table = [_]u8{ 1, 2, 3, 4 };
pub fn pick(n: u8) u8 {
    _ = n;
    return table[at];
}
