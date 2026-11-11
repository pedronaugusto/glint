// rule-small: a parameter declared `anytype` may be given a value, so the alias of it may be a value spelled as a type
fn Library(comptime R: anytype) type {
    return struct {
        pub const Role = R;
    };
}
pub const Small = Library(5);
