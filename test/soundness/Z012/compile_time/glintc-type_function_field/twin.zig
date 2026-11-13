// Z012: a private type function's struct is its own file's: a private type in its field is no
// public surface (gantry's report.zig Out, 8f).
const Marks = struct { count: u8 };
fn Out(comptime width: u8) type {
    return struct {
        marks: *const Marks,
        const size = width;
    };
}
pub fn render(marks: u8) u8 {
    const m: Marks = .{ .count = marks };
    const out: Out(4) = .{ .marks = &m };
    return out.marks.count;
}
