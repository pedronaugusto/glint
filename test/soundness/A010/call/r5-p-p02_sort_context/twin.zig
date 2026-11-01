// review 5: p/p02_sort_context.zig
const std = @import("std");
const table: [16]u8 = @splat(0);
const Ctx = struct {
    items: []u32,
    pub fn lessThan(ctx: Ctx, a: usize, b: usize) bool {
        return table[ctx.items[a]] < table[ctx.items[b]];
    }
    pub fn swap(ctx: Ctx, a: usize, b: usize) void {
        std.mem.swap(u32, &ctx.items[a], &ctx.items[b]);
    }
};
pub fn f(r: *std.Io.Reader) !void {
    var items: [4]u32 = undefined;
    for (&items) |*it| it.* = try r.takeInt(u32, .little);
    std.sort.pdqContext(0, items.len, Ctx{ .items = &items });
}
