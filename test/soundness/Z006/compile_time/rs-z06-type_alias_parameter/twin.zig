// rule-small: a parameter declared through an alias of `type` is a type for every binding
const Type = type;
fn Library(comptime R: Type) type {
    return struct {
        pub const Role = R;
    };
}
pub const Small = Library(u8);
