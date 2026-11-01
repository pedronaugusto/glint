// review 4: pp/i_hostcopy.zig
const Host = struct { issue_fn: *const fn (*Host) u32 };
const W = struct {
    n: u32 = 0,
    host: Host = .{ .issue_fn = issue },
    fn issue(h: *Host) u32 {
        const w: *W = @alignCast(@fieldParentPtr("host", h));
        return w.n;
    }
};
pub fn use(w: *W) u32 {
    var h2 = (&w.host).*;
    return h2.issue_fn(&h2);
}
