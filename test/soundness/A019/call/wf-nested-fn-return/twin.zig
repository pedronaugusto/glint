// A `return` in a function declared within the callee leaves that function, not the callee:
// the callee writes its parameter whole again before it returns.
const W = struct { data: [4]u8, n: u32 };
fn reset(w: *W, c: bool) void {
    w.* = undefined;
    const Local = struct {
        fn first(on: bool) u8 {
            if (on) return 1;
            return 0;
        }
    };
    w.* = .{ .data = .{ Local.first(c), 0, 0, 0 }, .n = 0 };
}
pub fn f(c: bool) u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    reset(&w, c);
    return w.data[0];
}
