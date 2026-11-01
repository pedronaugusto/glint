// glint-b: A002 unwrap (optional): the same shape made safe, which must stay clean
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(o: *?u32) u32 {
    return o.*.?;
}
