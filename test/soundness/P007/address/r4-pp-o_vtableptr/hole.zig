// review 4: pp/o_vtableptr.zig
const Observer = struct {
    vtable: *const VTable,
    pub const VTable = struct { see: *const fn (*Observer, u32) void };
    pub fn see(o: *Observer, n: u32) void {
        o.vtable.see(o, n);
    }
};
const Counter = struct {
    total: u32 = 0,
    observer: Observer = .{ .vtable = &vtable },
    const vtable: Observer.VTable = .{ .see = see };
    fn see(o: *Observer, n: u32) void {
        const self: *Counter = @alignCast(@fieldParentPtr("observer", o));
        self.total += n;
    }
};
const Fake = struct { pad: u8 = 0, observer: Observer };
pub fn run() u32 {
    const c: Counter = .{};
    var f: Fake = .{ .observer = .{ .vtable = c.observer.vtable } };
    f.pad = 1;
    f.observer.see(3);
    return c.total;
}
