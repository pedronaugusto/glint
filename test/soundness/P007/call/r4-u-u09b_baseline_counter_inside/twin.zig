// review 4: u/u09b_baseline_counter_inside.zig
// baseline (strict-review): counter and buffer in one scope (safe, expected clean on strict-review)
fn use(s: []const u8) u8 {
    return s[0];
}
pub fn main(rounds: usize) u8 {
    var buf: [8]u8 = undefined;
    var n: usize = 0;
    var last: u8 = 0;
    var i: usize = 0;
    while (i < rounds and n < buf.len) : (i += 1) {
        buf[n] = 7;
        n += 1;
        last = use(buf[0..n]);
    }
    return last;
}
