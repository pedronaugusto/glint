// Z026 twin: the continue expression counts the error
fn step(i: u32) error{Bad}!void {
    if (i == 3) return error.Bad;
}
fn done(i: u32) bool {
    return i > 5;
}
var failures: u32 = 0;
pub fn run() error{Exhausted}!void {
    var i: u32 = 0;
    while (i < 10) : (step(i) catch {
        failures += 1;
    }) {
        i += 1;
        if (done(i)) return;
    }
    return error.Exhausted;
}
