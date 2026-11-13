// Z005: a function that returns a type, named as a callable.
const Params = struct { Fe: type };
pub fn curve(comptime params: Params) type {
    return struct {
        pub const Fe = params.Fe;
    };
}
pub const C = curve(.{ .Fe = u64 });
