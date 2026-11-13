// Z012: the helper is reached only from a test block: no consumer reaches its public Tool
// (ensign's complete_test.zig, 8f).
pub fn answer() u8 {
    return 42;
}
test {
    _ = @import("module/helper.zig");
}
