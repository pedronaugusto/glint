const b = @import("b.zig");
const P = struct { data: u32 };
pub fn f(g: *P) u32 {
    return b.peek(g);
}
