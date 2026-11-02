// A019 compile_time: a comptime-known condition picks a branch, each of which writes
const fast = false;
pub fn get() u32 {
    var x: u32 = undefined;
    if (fast) x = 1 else x = 2;
    return x;
}
