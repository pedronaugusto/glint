// Z012: one suppression over a signature that exposes two private types: it may cover one
const A = struct { x: u8 };
const B = struct { y: u8 };
// glint-ignore: Z012 -- A is internal
pub fn f(a: A) B {
    return .{ .y = a.x };
}
