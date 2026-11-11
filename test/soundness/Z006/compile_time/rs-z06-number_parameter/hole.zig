// rule-small: a parameter declared `u8` is a number, so the alias of it is a value spelled as a type
fn Library(comptime R: u8) type {
    return struct {
        pub const Role = R;
    };
}
pub const Small = Library(5);
