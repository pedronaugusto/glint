// relic-b (pre-sweep-4): an integer cursor (`pos: usize`) written in two functions, switched on and
// moved by arithmetic on its own value: a counter, a value and no state set (A017's ruling, 11-06).
// ztreesitter src/regex.zig:94 `pos: usize`, clearance src/oauth/authorize.zig:59 `at: usize`, strand
// src/toml/temporal.zig:14 `month: u8`, shakedown src/Source.zig:38 `depth: u16`.
pub const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    pub fn next(p: *Parser) ?u8 {
        switch (p.pos) {
            0 => {},
            else => if (p.pos >= p.src.len) return null,
        }
        if (p.pos >= p.src.len) return null;
        p.pos += 1;
        return p.src[p.pos - 1];
    }
    pub fn back(p: *Parser) void {
        if (p.pos > 0) p.pos -= 1;
    }
};
