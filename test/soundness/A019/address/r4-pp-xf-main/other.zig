const main = @import("hole.zig");
pub fn go(c: *main.Counter) u32 {
    var copy = c.observer;
    copy.see(3);
    return c.total;
}
