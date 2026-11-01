// review 4: af/gc_16.zig
const S = @import("aegis").Secret;
pub fn use(s: S(u32)) void {
    h16(s);
}
fn h16(x: anytype) void {
    h15(x);
}
fn h15(x: anytype) void {
    h14(x);
}
fn h14(x: anytype) void {
    h13(x);
}
fn h13(x: anytype) void {
    h12(x);
}
fn h12(x: anytype) void {
    h11(x);
}
fn h11(x: anytype) void {
    h10(x);
}
fn h10(x: anytype) void {
    h9(x);
}
fn h9(x: anytype) void {
    h8(x);
}
fn h8(x: anytype) void {
    h7(x);
}
fn h7(x: anytype) void {
    h6(x);
}
fn h6(x: anytype) void {
    h5(x);
}
fn h5(x: anytype) void {
    h4(x);
}
fn h4(x: anytype) void {
    h3(x);
}
fn h3(x: anytype) void {
    h2(x);
}
fn h2(x: anytype) void {
    h1(x);
}
fn h1(x: anytype) void {
    h0(x);
}
fn h0(x: anytype) void {
    var kept = x;
    kept.deinit();
}
