// matrix: Z026 compile_time: an error the compiler evaluates, answered by its handler
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub const ready = blk: {
    fallible() catch break :blk false;
    break :blk true;
};
