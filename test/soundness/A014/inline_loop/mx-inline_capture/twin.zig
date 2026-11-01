// matrix: pointers into the caller's memory unrolled by an inline for and stored through the caller's pointer
pub fn f(out: **u32, into: *u32) void {
    into.* += 1;
    inline for (.{into}) |p| out.* = p;
}
