// warp-fast: the same ten helpers, the last of which only reads it
const std = @import("std");
const S = @import("before.zig").S;
fn h0(file: std.Io.File, io: std.Io) void {
    h1(file, io);
}
fn h1(file: std.Io.File, io: std.Io) void {
    h2(file, io);
}
fn h2(file: std.Io.File, io: std.Io) void {
    h3(file, io);
}
fn h3(file: std.Io.File, io: std.Io) void {
    h4(file, io);
}
fn h4(file: std.Io.File, io: std.Io) void {
    h5(file, io);
}
fn h5(file: std.Io.File, io: std.Io) void {
    h6(file, io);
}
fn h6(file: std.Io.File, io: std.Io) void {
    h7(file, io);
}
fn h7(file: std.Io.File, io: std.Io) void {
    h8(file, io);
}
fn h8(file: std.Io.File, io: std.Io) void {
    h9(file, io);
}
fn h9(file: std.Io.File, io: std.Io) void {
    h10(file, io);
}
fn h10(file: std.Io.File, io: std.Io) void {
    _ = file;
    _ = io;
}
pub fn go(s: *S, io: std.Io) void {
    h0(s.f, io);
}
