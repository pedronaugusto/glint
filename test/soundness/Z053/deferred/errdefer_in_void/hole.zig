// Z053: the reported form
var count: u32 = 0;
fn undo() void {
    count -= 1;
}
pub fn bump() void {
    count += 1;
    errdefer undo();
}
