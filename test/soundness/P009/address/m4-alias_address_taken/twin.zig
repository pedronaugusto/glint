// matrix: a local pointer given the caller's memory by a store of its own, then returned
pub fn f(caller: *u32) *u32 {
    caller.* += 1;
    var p: *u32 = undefined;
    p = caller;
    return p;
}
