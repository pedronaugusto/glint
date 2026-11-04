// P006 assignment: a comptime var holding one type, given another, its member read after:
// neither type's is disallowed
const S = struct {
    pub const x = 1;
};
const T = struct {
    pub const x = 2;
};
pub fn f() void {
    comptime var X: type = S;
    X = T;
    _ = X.x;
}
