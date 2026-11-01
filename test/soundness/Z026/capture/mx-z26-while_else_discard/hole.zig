// matrix: Z026 capture: a loop over an error union's payloads whose else captures the error by _ and drops it
fn next(n: *u32) error{Failure}!u32 {
    if (n.* == 3) return error.Failure;
    n.* += 1;
    return n.*;
}
pub fn run() u32 {
    var n: u32 = 0;
    var sum: u32 = 0;
    while (next(&n)) |item| {
        sum += item;
    } else |_| {}
    return sum;
}
