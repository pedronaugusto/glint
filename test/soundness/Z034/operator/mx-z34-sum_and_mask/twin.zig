// matrix: Z034 operator: the sum parenthesized under the mask
pub fn wrap(a: u32, b: u32, mask: u32) u32 {
    return (a +% b) & mask;
}
