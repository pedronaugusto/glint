// P009: a stack waiter linked into a list and unlinked by a defer before the function returns:
// the pointer never outlives the frame.
const Waiter = struct { next: ?*Waiter = null };
const Cond = struct {
    first: ?*Waiter = null,
    pub fn wait(self: *Cond) void {
        var waiter: Waiter = .{ .next = self.first };
        self.first = &waiter;
        defer {
            var link = &self.first;
            while (link.* != &waiter) link = &link.*.?.next;
            link.* = waiter.next;
        }
        park();
    }
};
fn park() void {}
pub fn g(c: *Cond) void {
    c.wait();
}
