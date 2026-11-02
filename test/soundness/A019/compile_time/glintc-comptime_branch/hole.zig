// A019 compile_time: a comptime-known false condition skips the only write
const fast = false;
pub fn get() u32 {
    var x: u32 = undefined;
    if (fast) x = 1;
    return x;
}
