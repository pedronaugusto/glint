// matrix: a pointer into the frame on orelse's right, stored where it outlives the call when the caller's is null
var last: ?*u32 = null;
pub fn f(given: ?*u32) void {
    var fallback: u32 = 0;
    fallback += 1;
    last = given orelse &fallback;
}
