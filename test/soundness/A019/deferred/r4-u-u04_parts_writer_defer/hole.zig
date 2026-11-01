// review 4: u/u04_parts_writer_defer.zig
// A019: a parts writer whose write is deferred; it hands the part on before the deferred write runs.
fn sink(s: []const u8) u8 {
    return s[0];
}
fn fill(p: *[8]u8) u8 {
    defer p[0..4].* = .{ 1, 2, 3, 4 };
    return sink(p[0..4]);
}
pub fn main() u8 {
    var buf: [8]u8 = undefined;
    return fill(&buf);
}
