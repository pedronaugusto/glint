// P006 field: names read off a comptime var holding one type, used on the var after it is
// given another (std.Io): the declaration is the same, the type is not
const S = struct { async: u8 };
pub fn f() void {
    comptime var X: type = S;
    const names = @typeInfo(X).@"struct".field_names;
    X = @import("std").Io;
    inline for (names) |name| _ = @field(X, name);
}
