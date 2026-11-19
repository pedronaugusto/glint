// Z057 twin: the call's result named in a statement before, so the load comes after it
fn reset(x: *u32) u32 {
    x.* = 0;
    return 1;
}
pub fn run() u32 {
    var x: u32 = 1;
    const n = reset(@as(*u32, &x));
    x += n;
    return x;
}
