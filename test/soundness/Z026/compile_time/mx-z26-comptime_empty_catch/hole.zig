// matrix: Z026 compile_time: an error the compiler evaluates, dropped by an empty catch
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub const ready = blk: {
    fallible() catch {};
    break :blk true;
};
