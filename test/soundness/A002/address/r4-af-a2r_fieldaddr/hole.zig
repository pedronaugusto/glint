// review 4: af/a2r_fieldaddr.zig
const bounded = @import("aegis").bounded;
const R = bounded.Budget(u32).Reservation;
const Hold = struct { maybe: ?R, list: [2]R };
pub fn f(b: *bounded.Budget(u32), out: **const u32) !void {
    var r = try b.reserve(1);
    out.* = &r.amount;
    var kept = r;
    kept.release();
}
