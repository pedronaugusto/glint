// P006 compile_time: a var holding type information, given another pointer's, read through
// its child: neither type's member is disallowed
const S = struct {
    pub const x = 1;
};
const T = struct {
    pub const x = 2;
};
pub fn f() void {
    comptime var info = @typeInfo(*const S);
    info = @typeInfo(*const T);
    _ = info.pointer.child.x;
}
