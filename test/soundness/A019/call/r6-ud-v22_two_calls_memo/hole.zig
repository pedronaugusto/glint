// review 6: ud/v22_two_calls_memo.zig
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
fn touch(w: *W) void { w.n += 1; }
// A first local reads the chain from the middle (k3); a second from the top, where the memo of
// the middle reading may answer.
pub fn f() u8 {
    var v: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    k3(&v);
    touch(&v);
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    k18(&w);
    return w.data[0];
}
