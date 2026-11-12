// Z026 (review 8, m6): a catch whose block only traps is catch unreachable.
fn parse(b: []const u8) !u8 {
    if (b.len == 0) return error.Empty;
    return b[0];
}
pub fn f(b: []const u8) u8 {
    return parse(b) catch {
        unreachable;
    };
}
