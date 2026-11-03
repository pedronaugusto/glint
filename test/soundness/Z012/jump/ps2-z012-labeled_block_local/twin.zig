pub const Hidden = struct { x: u8 };
pub const Api = blk: {
    const Inner = struct { inner: Hidden };
    break :blk Inner;
};
