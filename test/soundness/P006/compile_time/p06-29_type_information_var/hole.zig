// P006 compile_time: a var holding type information, given std.Io's pointer's, read through its child
const S = struct {
    pub const x = 1;
};
pub fn f() void {
    comptime var info = @typeInfo(*const S);
    info = @typeInfo(*const @import("std").Io);
    _ = info.pointer.child.async;
}
