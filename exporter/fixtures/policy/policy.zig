const Borrow = enum { never, prefer };
const Policy = struct { borrow: Borrow, depth: u8 };
fn read(comptime policy: Policy, x: u8) u8 {
    return if (policy.borrow == .prefer) x +% policy.depth else x;
}
export fn entry(a: u8) u8 {
    return read(.{ .borrow = .prefer, .depth = 3 }, a) +% read(.{ .borrow = .never, .depth = 0 }, a);
}
