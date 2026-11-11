// Z053 twin: the same done the way the rule leaves
var count: u32 = 0;
fn undo() void {
    count -= 1;
}
fn check() !void {}
pub fn bump() !void {
    count += 1;
    errdefer undo();
    try check();
}
