pub fn emit(comptime ns: type) void {
    ns.out("x\n", .{});
}
pub fn run() void {
    emit(@import("quiet.zig"));
}
