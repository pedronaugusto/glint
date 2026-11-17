// Z057 twin: the same done the way the rule leaves
fn reset(total: *u32) u32 {
    total.* = 0;
    return 1;
}
pub fn count() u32 {
    var total: u32 = 5;
    const added = reset(&total);
    total += added;
    return total;
}
