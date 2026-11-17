// Z057: the reported form
fn reset(total: *u32) u32 {
    total.* = 0;
    return 1;
}
pub fn count() u32 {
    var total: u32 = 5;
    total += reset(&total);
    return total;
}
