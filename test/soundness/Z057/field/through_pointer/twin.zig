// Z057 twin: the same done the way the rule leaves
const Counter = struct { n: u32 };
fn drain(counter: *Counter) u32 {
    counter.n = 0;
    return 1;
}
pub fn bump(counter: *Counter) void {
    const drained = drain(counter);
    counter.n += drained;
}
