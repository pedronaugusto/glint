// A019 unwrap: the callee's failure leaves the function (`try`), so the read after it follows a fill
fn fill(p: *[4]u8, c: bool) !void {
    if (c) return error.Skipped;
    p.* = .{ 1, 2, 3, 4 };
}
pub fn main(c: bool) !u8 {
    var buf: [4]u8 = undefined;
    try fill(&buf, c);
    return buf[3];
}
