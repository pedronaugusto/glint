fn one() u8 {
    return 1;
}
fn two() u8 {
    return 2;
}
export fn entry(pick: bool) u8 {
    const f: *const fn () u8 = if (pick) &one else &two;
    return f();
}
