fn Wide(comptime T: type) type {
    return [2]T;
}
fn first(comptime T: type, p: Wide(T)) T {
    return p[0];
}
fn swapped(comptime T: type, p: [2]T) Wide(T) {
    return .{ p[1], p[0] };
}
export fn entry(a: u8) u8 {
    const w: [2]u8 = .{ a, 1 };
    return first(u8, w) +% swapped(u8, w)[0];
}
