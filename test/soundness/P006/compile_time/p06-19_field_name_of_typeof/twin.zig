// P006 compile_time: the first field name of the type `@TypeOf` gives a value, named on that
// very value: a field, never a declaration
pub fn f(value: anytype) void {
    _ = @field(value, @typeInfo(@TypeOf(value)).@"struct".field_names[0]);
}
