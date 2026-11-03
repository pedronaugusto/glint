// glint-c: A014 call: a struct local that holds the frame's address from its init is handed to a function that stores nothing through it, then returned
const Seen = struct { at: []const u8, n: u32 };
fn count(s: *Seen) void {
    s.n += 1;
}
pub fn seen() Seen {
    var buf: [4]u8 = .{ 1, 2, 3, 4 };
    var out: Seen = .{ .at = &buf, .n = 0 };
    count(&out);
    return out;
}
