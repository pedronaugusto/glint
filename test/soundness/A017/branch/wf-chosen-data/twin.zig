// warp-fast: a run's length, which an if on it uses to choose a code point to read, the code point switched on
const table = [_]u21{ 'a', 'b', 'c', 'd' };
const Run = struct {
    one: u21 = 0,
    start: u32 = 0,
    len: u8 = 0,
    fn of(cp: u21) Run {
        if (cp < 'a') return .{ .one = cp, .len = 1 };
        return .{ .start = 0, .len = 3 };
    }
    fn at(p: Run, i: u8) u21 {
        return if (p.len == 1) p.one else table[p.start + i];
    }
};
pub const Reader = struct {
    run: Run = .{},
    index: u8 = 0,
    text: []const u21,
    at: usize = 0,
    pub fn next(r: *Reader) u21 {
        while (r.index == r.run.len) {
            r.index = 0;
            r.run = .of(r.text[r.at]);
            r.at += 1;
        }
        r.index += 1;
        return r.run.at(r.index - 1);
    }
    pub fn reset(r: *Reader) void {
        if (r.index < r.run.len) return;
        r.run = .{};
    }
};
fn dotted(cp: u21) bool {
    return switch (cp) {
        'i', 'j' => true,
        else => false,
    };
}
pub fn lastDotted(cp: u21) bool {
    const p: Run = .of(cp);
    return dotted(p.at(p.len - 1));
}
