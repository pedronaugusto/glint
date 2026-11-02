// A019 operator: `+=` reads what it updates, here still undefined
pub fn compound() u32 {
    var x: u32 = undefined;
    x += 1;
    return x;
}
