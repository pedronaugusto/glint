// twin: a @field with a computed name may name any declaration, so the file reports nothing
fn helper() u8 {
    return 1;
}
pub fn run(comptime name: []const u8) u8 {
    return @field(@This(), name)();
}
