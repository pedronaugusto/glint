// matrix: an owner's memory copied through a cast of its address, no std byte view
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H, out: []u8) void {
    @memcpy(out, @as([*]const u8, @ptrCast(&h.s))[0..@sizeOf(S)]);
}
