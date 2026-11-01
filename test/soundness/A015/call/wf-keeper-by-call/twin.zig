// warp-fast: the same keeper given a number through @call, which holds no resource
const Keeper = @import("before.zig").Keeper;
pub fn give(k: *Keeper) void {
    @call(.auto, Keeper.count, .{ k, 1 });
}
