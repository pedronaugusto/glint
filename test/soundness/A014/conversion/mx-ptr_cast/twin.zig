// matrix: a pointer into the caller's memory converted by @ptrCast, returned
pub fn f(into: *u32) *[4]u8 {
    into.* += 1;
    return @ptrCast(into);
}
