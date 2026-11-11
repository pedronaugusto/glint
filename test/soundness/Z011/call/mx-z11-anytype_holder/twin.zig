// matrix: Z011 call: a call through a holder whose type is not known (`anytype`): its callee does
// not resolve, and an unresolved callee is silent (a miss is allowed, a wrong report is not)
/// Deprecated: use `fresh`.
fn old() void {}
fn fresh() void {}
pub fn run(holder: anytype) void {
    holder.old();
}
