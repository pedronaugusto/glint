// A019 branch: a switch's else prong does not write; the read after it may read undefined
pub fn someProngs(v: u8) u32 {
    var x: u32 = undefined;
    switch (v) {
        0 => x = 1,
        1 => x = 2,
        else => {},
    }
    return x;
}
