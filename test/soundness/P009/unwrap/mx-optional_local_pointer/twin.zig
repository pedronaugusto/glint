// matrix: a pointer into the caller's memory held in a local optional, returned through `.?`
pub fn f(into: *u32) *u32 {
    into.* += 1;
    const maybe: ?*u32 = into;
    return maybe.?;
}
