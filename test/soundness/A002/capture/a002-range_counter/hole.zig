// a002: A002 capture (range counter): an element's address chosen beside the counter, returned, which must flag
const S = @import("aegis").Secret;
pub fn f(s: *S([4]u8), want: u8) ?*const u8 {
    const bytes = s.expose();
    for (bytes, 0..) |*b, i| if (b.* == want and i != 0) return b;
    return null;
}
