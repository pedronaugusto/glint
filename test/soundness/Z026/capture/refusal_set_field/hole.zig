// Z026: an empty error branch on a callee whose inferred set holds OutOfMemory, returned as a set's member
const E = error{ OutOfMemory, Invalid };
fn parse(x: u8) !u8 {
    if (x == 0) return E.OutOfMemory;
    if (x == 1) return error.Invalid;
    return x;
}
pub fn run(x: u8) u8 {
    if (parse(x)) |v| {
        return v;
    } else |_| {}
    return 0;
}
