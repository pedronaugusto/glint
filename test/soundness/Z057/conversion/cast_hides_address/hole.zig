// Z057: the call is handed the place the left side updates, its address behind a cast
fn reset(x: *u32) u32 {
    x.* = 0;
    return 1;
}
pub fn run() u32 {
    var x: u32 = 1;
    x += reset(@as(*u32, &x));
    return x;
}
