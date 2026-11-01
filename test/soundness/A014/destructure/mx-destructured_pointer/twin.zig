// matrix: a pointer into the caller's memory taken out of a tuple by a destructure, then returned
pub fn f(into: *u32) *u32 {
    into.* += 1;
    const p, const n = .{ into, @as(u32, 0) };
    _ = n;
    return p;
}
