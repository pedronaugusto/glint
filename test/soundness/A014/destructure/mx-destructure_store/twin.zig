// matrix: a pointer into the caller's memory stored through the caller's pointer by a destructuring assignment
pub fn f(out: **u32, count: *u32, into: *u32) void {
    into.* += 1;
    out.*, count.* = .{ into, 1 };
}
