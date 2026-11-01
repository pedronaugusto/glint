// matrix A009 call: input given as the 2nd of 32 arguments, which the function never reads; the last, which indexes, is a constant
const std = @import("std");
fn wide(table: *const [16]u8, a1: u8, a2: u8, a3: u8, a4: u8, a5: u8, a6: u8, a7: u8, a8: u8, a9: u8, a10: u8, a11: u8, a12: u8, a13: u8, a14: u8, a15: u8, a16: u8, a17: u8, a18: u8, a19: u8, a20: u8, a21: u8, a22: u8, a23: u8, a24: u8, a25: u8, a26: u8, a27: u8, a28: u8, a29: u8, a30: u8, a31: u8) u8 {
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    _ = a5;
    _ = a6;
    _ = a7;
    _ = a8;
    _ = a9;
    _ = a10;
    _ = a11;
    _ = a12;
    _ = a13;
    _ = a14;
    _ = a15;
    _ = a16;
    _ = a17;
    _ = a18;
    _ = a19;
    _ = a20;
    _ = a21;
    _ = a22;
    _ = a23;
    _ = a24;
    _ = a25;
    _ = a26;
    _ = a27;
    _ = a28;
    _ = a29;
    _ = a30;
    return table[a31];
}
pub fn f(r: *std.Io.Reader, table: *const [16]u8) !u8 {
    const n = try r.takeByte();
    return wide(table, n, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}
