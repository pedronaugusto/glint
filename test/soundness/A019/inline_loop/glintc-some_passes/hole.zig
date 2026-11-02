// A019 inline_loop: no unrolled pass writes (each pass's condition is false); the read after it reads undefined
pub fn somePasses() u32 {
    var x: u32 = undefined;
    inline for (.{ 0, 1 }) |k| {
        if (k == 5) x = k;
    }
    return x;
}
