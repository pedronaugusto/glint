// matrix: a pointer to static storage on orelse's right, stored when the caller's is null
var last: ?*u32 = null;
var fallback: u32 = 0;
pub fn f(given: ?*u32) void {
    last = given orelse &fallback;
}
