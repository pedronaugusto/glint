// gantry src/frontends/zig.zig's Bridge over src/frontend.zig's Lexeme: each unit is made where it
// is read, with its kind from the token, and a guard on that unit's kind chooses whether the
// pending operator is set to a fixed kind or cleared (`null`). A clear holds no record; a guard
// on a record made here chooses by data, not by the pending operator's own value. No state machine.
pub const Lexeme = struct {
    kind: enum { word, string, punctuation },
    end: usize,
    pub fn is(t: Lexeme) bool {
        return t.kind == .word or t.kind == .punctuation;
    }
};
pub const Bridge = struct {
    operator: ?Lexeme = null,
    last: Lexeme = .{ .kind = .word, .end = 0 },
    pub fn token(b: *Bridge, punctuation: bool, end: usize) void {
        const unit: Lexeme = .{ .kind = if (punctuation) .punctuation else .word, .end = end };
        if (unit.kind != .punctuation) return b.deliver(unit);
        if (b.operator) |operator| {
            if (unit.end != operator.end) return;
            b.operator = null;
            return b.deliver(operator);
        }
        b.operator = .{ .kind = .punctuation, .end = end + 1 };
    }
    fn deliver(b: *Bridge, unit: Lexeme) void {
        b.last = unit;
    }
    pub fn boundary(b: *Bridge) void {
        b.operator = null;
    }
};
// The unit's kind is the pending record's: a guard on it is one on that record's own value.
pub fn settle(b: *Bridge) void {
    const unit: Lexeme = .{ .kind = b.last.kind, .end = 0 };
    if (unit.kind == .word) b.last = .{ .kind = .string, .end = 1 };
}
pub fn weight(l: Lexeme) u8 {
    return switch (l.kind) {
        .word => 1,
        .string => 2,
        .punctuation => 3,
    };
}
