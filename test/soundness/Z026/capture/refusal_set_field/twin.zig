// Z026 twin: the error branch keeps the error
const E = error{ OutOfMemory, Invalid };
fn parse(x: u8) !u8 {
    if (x == 0) return E.OutOfMemory;
    if (x == 1) return error.Invalid;
    return x;
}
var last: ?anyerror = null;
pub fn run(x: u8) u8 {
    if (parse(x)) |v| {
        return v;
    } else |err| {
        last = err;
    }
    return 0;
}
