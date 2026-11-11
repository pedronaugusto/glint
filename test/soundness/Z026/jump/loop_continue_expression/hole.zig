// Z026: an empty catch in a loop's continue expression, a return below it
fn step(i: u32) error{Bad}!void {
    if (i == 3) return error.Bad;
}
fn done(i: u32) bool {
    return i > 5;
}
pub fn run() error{Exhausted}!void {
    var i: u32 = 0;
    while (i < 10) : (step(i) catch {}) {
        i += 1;
        if (done(i)) return;
    }
    return error.Exhausted;
}
