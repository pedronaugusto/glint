// twin: a callee that does not resolve (a member of an `anytype` value) is silent, not undecided
pub fn check(checks: anytype, a: bool, b: bool) void {
    checks.assert(a and b);
}
