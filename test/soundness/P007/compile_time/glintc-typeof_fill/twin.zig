// A019 compile_time: a call inside @TypeOf is never run; the local is written at run time before the read
fn fill(p: *[4]u8) void {
    p.* = .{ 1, 2, 3, 4 };
}
pub fn main() u8 {
    var buf: [4]u8 = undefined;
    const T = @TypeOf(fill(&buf));
    fill(&buf);
    if (T != void) return 0;
    return buf[3];
}
