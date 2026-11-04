// P006 address: one element of a type parameter's field names, named on a value of that very
// type: a field, never a declaration
pub fn f(comptime T: type, value: anytype) T {
    var out: T = undefined;
    @field(out, @typeInfo(T).@"struct".field_names[0]) = value;
    return out;
}
