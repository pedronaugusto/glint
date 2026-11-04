// P006 compile_time: the first field name of the type `@TypeOf` gives one value, named on
// another (aegis's representation fixture); with `a` a struct holding `async` and `b` std.Io's
// type, the disallowed std.Io.async is reached
pub fn f(a: anytype, comptime b: type) void {
    _ = @field(b, @typeInfo(@TypeOf(a)).@"struct".field_names[0]);
}
