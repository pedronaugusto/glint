// matrix: a defer stores a pointer into the caller's memory
pub fn f(out: **u32, into: *u32) void {
    into.* += 1;
    defer out.* = into;
}
