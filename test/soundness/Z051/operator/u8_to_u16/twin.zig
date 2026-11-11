// Z051 twin: the same done the way the rule leaves
pub fn count(n: u16) u16 {
    var i: u16 = 0;
    var total: u16 = 0;
    while (i < n) : (i += 1) total += 1;
    return total;
}
