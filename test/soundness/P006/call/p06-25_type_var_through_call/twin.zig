// P006 call: a var given a type through @call, then another: neither type's member is
// disallowed
fn Id(comptime U: type) type {
    return U;
}
const S = struct {
    pub const x = 1;
};
const T = struct {
    pub const x = 2;
};
pub fn f() void {
    comptime var X = @call(.auto, Id, .{S});
    X = T;
    _ = X.x;
}
