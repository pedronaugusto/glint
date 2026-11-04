// P006 capture: the field names a `switch (@typeInfo(T))` prong captures, named on a value of
// that very type: a field, never a declaration
pub fn f(comptime T: type) T {
    var out: T = undefined;
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.field_names) |name| {
            @field(out, name) = undefined;
        },
        else => {},
    }
    return out;
}
