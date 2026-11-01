// review 4: u/u12c_parent_parts.zig
// A019: parts tracking with the interface exception in force: c.observer set by c.init(), 'total'
// never written, and see() (installed only by Counter's own init) reads self.total.
const Observer = struct {
    vtable: *const VTable,
    pub const VTable = struct { see: *const fn (*Observer, u32) void };
    pub fn see(o: *Observer, n: u32) void {
        o.vtable.see(o, n);
    }
};
const Counter = struct {
    total: u32,
    observer: Observer,
    const vtable: Observer.VTable = .{ .see = see };
    fn see(o: *Observer, n: u32) void {
        const self: *Counter = @alignCast(@fieldParentPtr("observer", o));
        self.total += n;
    }
    fn init(c: *Counter) void {
        c.observer = .{ .vtable = &vtable };
    }
};
pub fn run() void {
    var c: Counter = undefined;
    c.init();
    c.observer.see(3);
}
