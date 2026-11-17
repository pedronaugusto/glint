// Z057: the reported form
const Counter = struct { n: u32 };
fn drain(counter: *Counter) u32 {
    counter.n = 0;
    return 1;
}
pub fn bump(counter: *Counter) void {
    counter.n += drain(counter);
}
