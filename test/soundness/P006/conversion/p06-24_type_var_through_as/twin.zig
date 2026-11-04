// P006 conversion: a var given a type through @as, then another: neither type's member is
// disallowed
const S = struct {
    pub const x = 1;
};
const T = struct {
    pub const x = 2;
};
pub fn f() void {
    comptime var X = @as(type, S);
    X = T;
    _ = X.x;
}
