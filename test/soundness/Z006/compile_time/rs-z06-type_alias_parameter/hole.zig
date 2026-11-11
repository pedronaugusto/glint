// rule-small: a parameter declared with the program's own struct named `Type` is a value of it, not a type
const Type = struct { width: u8 };
fn Library(comptime R: Type) type {
    return struct {
        pub const Role = R;
    };
}
pub const Small = Library(.{ .width = 5 });
