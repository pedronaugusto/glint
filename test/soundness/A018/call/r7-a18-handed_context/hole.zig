// review 7: a function handed out with its context, which a hook that does not resolve may
// point at a peer's writer, writes an error's name through it
const std = @import("std");
const Ctx = struct {
    out: *std.Io.Writer,
    hook: *const fn (*Ctx) void,
};
fn record(ctx: *Ctx, e: anyerror) void {
    ctx.hook(ctx);
    ctx.out.print("{s}\n", .{@errorName(e)}) catch {};
}
pub const handler = &record;
