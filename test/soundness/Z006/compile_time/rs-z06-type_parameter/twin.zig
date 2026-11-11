// rule-small: a parameter declared `type` is a type for every binding, so the alias of it is a type
fn Library(comptime R: type) type {
    return struct {
        pub const Role = R;
    };
}
pub const Small = Library(u8);
