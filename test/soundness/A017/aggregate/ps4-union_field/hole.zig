// A017: the same shape on an enum field: a state machine kept by hand.
pub const Parser = struct {
    src: []const u8,
    at: usize = 0,
    phase: enum { start, body, done } = .start,
    pub fn next(p: *Parser) ?u8 {
        switch (p.phase) {
            .start => p.phase = .body,
            .body => if (p.at >= p.src.len) {
                p.phase = .done;
                return null;
            },
            .done => return null,
        }
        p.at += 1;
        return p.src[p.at - 1];
    }
    pub fn reset(p: *Parser) void {
        if (p.phase == .done) p.phase = .start;
    }
};
