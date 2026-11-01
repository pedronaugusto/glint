// matrix: a pointer into the caller's memory put into an array literal, returned
pub fn f(into: *u32) [1]*u32 {
    into.* += 1;
    return .{into};
}
