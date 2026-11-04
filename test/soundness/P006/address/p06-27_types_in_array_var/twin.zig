// P006 address: a var holding an array of types, given another array whole: neither type's
// member is disallowed
const S = struct {
    pub const x = 1;
};
const T = struct {
    pub const x = 2;
};
pub fn f() void {
    comptime var ts = [_]type{S};
    ts = [_]type{T};
    _ = ts[0].x;
}
