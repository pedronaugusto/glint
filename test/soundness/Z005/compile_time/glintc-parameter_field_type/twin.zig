// Z005: a function returning a value of the type a comptime parameter's field names
// (`Fe: type`) returns a value, not a type: callable naming is right (cloak's weierstrass, 8d).
const Params = struct { Fe: type };
pub fn Curve(comptime params: Params) type {
    return struct {
        pub const Fe = params.Fe;
        pub fn rhs(x: *const Fe) Fe {
            return x.*;
        }
    };
}
pub const C = Curve(.{ .Fe = u64 });
