// review 7: a function handed out with its context, given to a hook that does not resolve,
// keeps an error's name in a list of bytes, which no peer's writer is
const std = @import("std");
const Ctx = struct {
    gpa: std.mem.Allocator,
    names: std.ArrayList(u8),
    hook: *const fn (*Ctx) void,
};
fn record(ctx: *Ctx, e: anyerror) void {
    ctx.hook(ctx);
    ctx.names.appendSlice(ctx.gpa, @errorName(e)) catch {};
}
pub const handler = &record;
