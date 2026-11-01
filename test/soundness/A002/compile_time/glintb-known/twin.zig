// glint-b: A002 compile_time (known): the same shape made safe, which must stay clean
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H) u32 {
    const name = "n";
    return @field(h, name);
}
