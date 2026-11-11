// Z012 twin: the suppression covers the one private type the signature exposes
const A = struct { x: u8 };
pub const B = struct { y: u8 };
// glint-ignore: Z012 -- A is internal
pub fn f(a: A) B {
    return .{ .y = a.x };
}
