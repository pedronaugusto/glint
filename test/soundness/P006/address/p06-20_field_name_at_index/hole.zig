// P006 address: one element of a type parameter's field names, named on another type (aegis's
// import fixture); with `T` a struct holding `async` and `U` std.Io, the disallowed
// std.Io.async is reached
pub fn f(comptime T: type, comptime U: type) void {
    _ = @field(U, @typeInfo(T).@"struct".field_names[0]);
}
