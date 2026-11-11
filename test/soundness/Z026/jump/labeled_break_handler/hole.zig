// Z026: an empty handler spelled as a labeled block that breaks with no value
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run() void {
    fallible() catch blk: {
        break :blk;
    };
}
