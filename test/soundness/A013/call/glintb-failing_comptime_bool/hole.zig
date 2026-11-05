// glint-b: a callee read at its call's binding, given `careful = true`: its failing exit is taken there
const std = @import("std");
fn load(comptime careful: bool, have: usize, n: usize) !usize {
    if (!careful) return n;
    if (have < n) return error.NeedInput;
    return n;
}
pub fn f(r: *std.Io.Reader) !usize {
    const in = try r.take(8);
    return load(true, in[0], in[1]) catch unreachable;
}
