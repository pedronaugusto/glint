// A019 branch: every prong of the switch writes; the read after it reads a value
pub fn everyProng(v: u8) u32 {
    var x: u32 = undefined;
    switch (v) {
        0 => x = 1,
        1 => x = 2,
        else => x = 3,
    }
    return x;
}
