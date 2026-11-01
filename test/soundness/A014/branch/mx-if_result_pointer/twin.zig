// matrix: a pointer to static storage chosen by an if expression, stored
var last: ?*u32 = null;
var fallback: u32 = 0;
pub fn f(given: ?*u32) void {
    last = if (given) |p| p else &fallback;
}
