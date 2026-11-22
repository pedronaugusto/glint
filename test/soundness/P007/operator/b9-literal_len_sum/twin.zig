// P007: a string literal's length plus an integer, as an index and a slice bound: integer
// arithmetic, no pointer in it.
const prefix = "holder ";
pub fn f(text: []u8, digits: usize) []u8 {
    text[prefix.len + digits] = '\n';
    return text[0 .. prefix.len + digits + 1];
}
