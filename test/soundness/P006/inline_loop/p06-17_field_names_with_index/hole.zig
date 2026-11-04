// P006 inline_loop: each field name of one type parameter, ranged over with its index, named on
// another (aegis's flat writer); with `T` a struct holding `async` and `U` std.Io, the
// disallowed std.Io.async is reached
pub fn f(comptime T: type, comptime U: type) void {
    inline for (@typeInfo(T).@"struct".field_names, 0..) |name, i| {
        _ = i;
        _ = @field(U, name);
    }
}
