// review 6: ud/v21_deep_chain.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
fn k0(w: *W) void { w.* = undefined; }
fn k1(w: *W) void { k0(w); }
fn k2(w: *W) void { k1(w); }
fn k3(w: *W) void { k2(w); }
fn k4(w: *W) void { k3(w); }
fn k5(w: *W) void { k4(w); }
fn k6(w: *W) void { k5(w); }
fn k7(w: *W) void { k6(w); }
fn k8(w: *W) void { k7(w); }
fn k9(w: *W) void { k8(w); }
fn k10(w: *W) void { k9(w); }
fn k11(w: *W) void { k10(w); }
fn k12(w: *W) void { k11(w); }
fn k13(w: *W) void { k12(w); }
fn k14(w: *W) void { k13(w); }
fn k15(w: *W) void { k14(w); }
fn k16(w: *W) void { k15(w); }
fn k17(w: *W) void { k16(w); }
fn k18(w: *W) void { k17(w); }
// Past the depth read: undecided, never clean.
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    k18(&w);
    return w.data[0];
}
