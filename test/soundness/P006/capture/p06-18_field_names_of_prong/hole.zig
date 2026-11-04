// P006 capture: the field names a `switch (@typeInfo(T))` prong captures, named on another type
// (aegis's flat reader); with `T` a struct holding `async` and `U` std.Io, the disallowed
// std.Io.async is reached
pub fn f(comptime T: type, comptime U: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.field_names) |name| {
            _ = @field(U, name);
        },
        else => {},
    }
}
