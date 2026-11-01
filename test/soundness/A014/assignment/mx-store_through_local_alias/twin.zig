// matrix: a pointer into the caller's memory stored through a local copy of the caller's pointer
pub fn f(out: **u32, into: *u32) void {
    into.* += 1;
    const slot = out;
    slot.* = into;
}
