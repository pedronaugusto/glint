// A019 operator: `+=` reads what it updates, written first
pub fn compound() u32 {
    var x: u32 = undefined;
    x = 1;
    x += 1;
    return x;
}
