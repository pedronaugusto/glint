// review 4: af/a2r_extcall_base.zig
const std = @import("std");
const bounded = @import("aegis").bounded;
const R = bounded.Budget(u32).Reservation;
pub fn f(b: *bounded.Budget(u32), list: *std.ArrayList(R)) !void {
    const r = try b.reserve(1);
    var kept = r;
    list.appendAssumeCapacity(r);
    kept.release();
}
