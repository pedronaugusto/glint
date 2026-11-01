// review 4: u/u12b_parent_name_literal.zig
// baseline: the same with the field named by a literal (expected: the use of c.observer read as all of c)
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
};
pub fn run() u32 {
    var c: Counter = undefined;
    c.observer = .{ .vtable = &Counter.vtable };
    c.observer.see(3);
    return 0;
}
