// a002: A002 capture (range counter): the counter returned, which holds no address and must stay clean
const S = @import("aegis").Secret;
pub fn f(s: *S([4]u8), want: u8) ?usize {
    const bytes = s.expose();
    for (bytes, 0..) |b, i| if (b == want) return i;
    return null;
}
