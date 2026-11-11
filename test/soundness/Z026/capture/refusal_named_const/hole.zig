// Z026: an empty error branch on a callee whose OutOfMemory comes through a constant of the set's member
const oom = error{OutOfMemory}.OutOfMemory;
fn parse(x: u8) !u8 {
    if (x == 0) return oom;
    if (x == 1) return error.Invalid;
    return x;
}
pub fn run(x: u8) u8 {
    if (parse(x)) |v| {
        return v;
    } else |_| {}
    return 0;
}
