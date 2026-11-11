// twin
fn total() u8 {
    return 1;
}
pub fn run(x: u8) u8 {
    return sum: {
        if (x == 0) break :sum total();
        break :sum x;
    };
}
