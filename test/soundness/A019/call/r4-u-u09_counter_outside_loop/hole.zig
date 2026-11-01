// review 4: u/u09_counter_outside_loop.zig
// A019 (strict-review appended counter): the counter outlives the buffer, declared afresh each pass.
fn use(s: []const u8) u8 {
    return s[0];
}
pub fn main(rounds: usize) u8 {
    var n: usize = 0;
    var last: u8 = 0;
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        var buf: [8]u8 = undefined;
        buf[n] = 7;
        n += 1;
        last = use(buf[0..n]);
    }
    return last;
}
