// matrix: a pointer into the caller's memory coerced by @as to a const pointer, stored
var last: ?*const u32 = null;
pub fn f(into: *u32) void {
    into.* += 1;
    last = @as(*const u32, into);
}
