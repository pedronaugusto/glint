// A callback's context cast back to its own state through @alignCast: the cast keeps an
// opaque pointer, which holds no scalar, and the state is a plain counter.
const aegis = @import("aegis");
const Cancel = struct {
    calls: usize = 0,
    after: usize,
    fn check(ctx: ?*anyopaque) bool {
        const self: *Cancel = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        return self.calls >= self.after;
    }
};
pub fn run(c: *Cancel) bool {
    _ = aegis;
    return Cancel.check(c);
}
