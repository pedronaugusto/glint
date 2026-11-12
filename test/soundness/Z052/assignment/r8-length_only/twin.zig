// Z052 (review 8, m12): the constant's length is its type's; no byte of it is read.
const scratch: [16]u8 = undefined;
pub fn capacity() usize {
    return scratch.len;
}
