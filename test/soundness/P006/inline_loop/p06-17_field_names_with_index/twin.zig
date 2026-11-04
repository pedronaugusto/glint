// P006 inline_loop: each field name of a type parameter, ranged over with its index, named on a
// value of that very type: a field, never a declaration
pub fn f(comptime T: type, value: T) void {
    inline for (@typeInfo(T).@"struct".field_names, 0..) |name, i| {
        _ = i;
        _ = @field(value, name);
    }
}
