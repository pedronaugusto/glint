// review 4: af/ord2/chain64.zig
const std = @import("std");
const s0 = @import("src0.zig");
pub fn sink(r: *std.Io.Reader, table: []const u8) !u8 {
    return table[try g64(r)];
}
fn g64(r: *std.Io.Reader) !u32 {
    return g63(r);
}
fn g63(r: *std.Io.Reader) !u32 {
    return g62(r);
}
fn g62(r: *std.Io.Reader) !u32 {
    return g61(r);
}
fn g61(r: *std.Io.Reader) !u32 {
    return g60(r);
}
fn g60(r: *std.Io.Reader) !u32 {
    return g59(r);
}
fn g59(r: *std.Io.Reader) !u32 {
    return g58(r);
}
fn g58(r: *std.Io.Reader) !u32 {
    return g57(r);
}
fn g57(r: *std.Io.Reader) !u32 {
    return g56(r);
}
fn g56(r: *std.Io.Reader) !u32 {
    return g55(r);
}
fn g55(r: *std.Io.Reader) !u32 {
    return g54(r);
}
fn g54(r: *std.Io.Reader) !u32 {
    return g53(r);
}
fn g53(r: *std.Io.Reader) !u32 {
    return g52(r);
}
fn g52(r: *std.Io.Reader) !u32 {
    return g51(r);
}
fn g51(r: *std.Io.Reader) !u32 {
    return g50(r);
}
fn g50(r: *std.Io.Reader) !u32 {
    return g49(r);
}
fn g49(r: *std.Io.Reader) !u32 {
    return g48(r);
}
fn g48(r: *std.Io.Reader) !u32 {
    return g47(r);
}
fn g47(r: *std.Io.Reader) !u32 {
    return g46(r);
}
fn g46(r: *std.Io.Reader) !u32 {
    return g45(r);
}
fn g45(r: *std.Io.Reader) !u32 {
    return g44(r);
}
fn g44(r: *std.Io.Reader) !u32 {
    return g43(r);
}
fn g43(r: *std.Io.Reader) !u32 {
    return g42(r);
}
fn g42(r: *std.Io.Reader) !u32 {
    return g41(r);
}
fn g41(r: *std.Io.Reader) !u32 {
    return g40(r);
}
fn g40(r: *std.Io.Reader) !u32 {
    return g39(r);
}
fn g39(r: *std.Io.Reader) !u32 {
    return g38(r);
}
fn g38(r: *std.Io.Reader) !u32 {
    return g37(r);
}
fn g37(r: *std.Io.Reader) !u32 {
    return g36(r);
}
fn g36(r: *std.Io.Reader) !u32 {
    return g35(r);
}
fn g35(r: *std.Io.Reader) !u32 {
    return g34(r);
}
fn g34(r: *std.Io.Reader) !u32 {
    return g33(r);
}
fn g33(r: *std.Io.Reader) !u32 {
    return g32(r);
}
fn g32(r: *std.Io.Reader) !u32 {
    return g31(r);
}
fn g31(r: *std.Io.Reader) !u32 {
    return g30(r);
}
fn g30(r: *std.Io.Reader) !u32 {
    return g29(r);
}
fn g29(r: *std.Io.Reader) !u32 {
    return g28(r);
}
fn g28(r: *std.Io.Reader) !u32 {
    return g27(r);
}
fn g27(r: *std.Io.Reader) !u32 {
    return g26(r);
}
fn g26(r: *std.Io.Reader) !u32 {
    return g25(r);
}
fn g25(r: *std.Io.Reader) !u32 {
    return g24(r);
}
fn g24(r: *std.Io.Reader) !u32 {
    return g23(r);
}
fn g23(r: *std.Io.Reader) !u32 {
    return g22(r);
}
fn g22(r: *std.Io.Reader) !u32 {
    return g21(r);
}
fn g21(r: *std.Io.Reader) !u32 {
    return g20(r);
}
fn g20(r: *std.Io.Reader) !u32 {
    return g19(r);
}
fn g19(r: *std.Io.Reader) !u32 {
    return g18(r);
}
fn g18(r: *std.Io.Reader) !u32 {
    return g17(r);
}
fn g17(r: *std.Io.Reader) !u32 {
    return g16(r);
}
fn g16(r: *std.Io.Reader) !u32 {
    return g15(r);
}
fn g15(r: *std.Io.Reader) !u32 {
    return g14(r);
}
fn g14(r: *std.Io.Reader) !u32 {
    return g13(r);
}
fn g13(r: *std.Io.Reader) !u32 {
    return g12(r);
}
fn g12(r: *std.Io.Reader) !u32 {
    return g11(r);
}
fn g11(r: *std.Io.Reader) !u32 {
    return g10(r);
}
fn g10(r: *std.Io.Reader) !u32 {
    return g9(r);
}
fn g9(r: *std.Io.Reader) !u32 {
    return g8(r);
}
fn g8(r: *std.Io.Reader) !u32 {
    return g7(r);
}
fn g7(r: *std.Io.Reader) !u32 {
    return g6(r);
}
fn g6(r: *std.Io.Reader) !u32 {
    return g5(r);
}
fn g5(r: *std.Io.Reader) !u32 {
    return g4(r);
}
fn g4(r: *std.Io.Reader) !u32 {
    return g3(r);
}
fn g3(r: *std.Io.Reader) !u32 {
    return g2(r);
}
fn g2(r: *std.Io.Reader) !u32 {
    return g1(r);
}
fn g1(r: *std.Io.Reader) !u32 {
    return s0.g0(r);
}
