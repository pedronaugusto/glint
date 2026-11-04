// P006 field: a tag's name of a type parameter named on that very type: a tag, never a
// declaration, whatever the type is
pub fn f(comptime E: type, comptime e: E) void {
    _ = @field(E, @tagName(e));
}
