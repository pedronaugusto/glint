// Z026: a catch whose prong returns the error handles it.
fn parse(b: []const u8) !u8 {
    if (b.len == 0) return error.Empty;
    return b[0];
}
pub fn f(b: []const u8) !u8 {
    return parse(b) catch |e| switch (e) {
        error.Empty => return e,
    };
}
