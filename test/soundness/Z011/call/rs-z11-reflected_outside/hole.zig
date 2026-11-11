// rule-small: a deprecated function reached by reflection in a module outside the run, over a type the run hands it, and called through the pointer that module returns: no value reference names it in the run, so the call is the one place left to judge it
const dep = @import("dep");
const Old = struct {
    /// Deprecated: use `fresh`.
    pub fn stale() void {}
};
pub fn run() void {
    const f = dep.first(Old);
    f();
}
