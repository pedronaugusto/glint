// review 4: pp/i_secondparam_helper.zig
const Host = struct { issue_fn: *const fn (*Host, *Host) u32 };
const W = struct {
    n: u32 = 0,
    host: Host = .{ .issue_fn = issue },
    fn of(h: *Host) *W {
        return @alignCast(@fieldParentPtr("host", h));
    }
    fn issue(h: *Host, other: *Host) u32 {
        _ = h;
        return of(other).n;
    }
};
pub fn use(w: *W, stranger: *Host) u32 {
    return w.host.issue_fn(&w.host, stranger);
}
