// twin: a function only a dead function calls is used; no reachability is read
fn helper() u8 {
    return 1;
}
// glint-ignore: D001 -- kept for the port that lands next
fn caller() u8 {
    return helper();
}
pub const one = 1;
