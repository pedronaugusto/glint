// P006 field: a tag's name of one type parameter named on another (the state's tag on the union
// a machine holds, aegis's Carrying); with `E` an enum holding `async` and `U` std.Io, the
// disallowed std.Io.async is reached
pub fn f(comptime E: type, comptime U: type, comptime e: E) void {
    _ = @field(U, @tagName(e));
}
