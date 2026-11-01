// review 4: af/a2r_extcall.zig
const std = @import("std");
const bounded = @import("aegis").bounded;
const R = bounded.Budget(u32).Reservation;
pub fn f(b: *bounded.Budget(u32), list: *std.ArrayList(R)) !void {
    const r = try b.reserve(1);
    list.appendAssumeCapacity(r);
    var kept = r;
    kept.release();
}
