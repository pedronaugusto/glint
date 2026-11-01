// review 4: u/u12_parent_name_const.zig
// A019: parts tracking keeps 'total' undefined while 'observer' is set; the installed see() converts
// &c.observer back to the Counter and reads 'total'. The @fieldParentPtr names the field through a
// constant, so the parts check does not see that this field may give its struct.
const Observer = struct {
    vtable: *const VTable,
    pub const VTable = struct { see: *const fn (*Observer, u32) void };
    pub fn see(o: *Observer, n: u32) void {
        o.vtable.see(o, n);
    }
};
const field = "observer";
const Counter = struct {
    total: u32,
    observer: Observer,
    const vtable: Observer.VTable = .{ .see = see };
    fn see(o: *Observer, n: u32) void {
        const self: *Counter = @alignCast(@fieldParentPtr(field, o));
        self.total += n;
    }
    fn init(c: *Counter) void {
        c.observer = .{ .vtable = &vtable };
    }
};
pub fn run() u32 {
    var c: Counter = undefined;
    c.observer = .{ .vtable = &Counter.vtable };
    c.observer.see(3);
    return 0;
}
