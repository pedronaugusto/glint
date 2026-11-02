// A019 deferred: the write is deferred, so the read before the scope's exit reads undefined
pub fn deferredWrite() u32 {
    var x: u32 = undefined;
    defer x = 1;
    return x;
}
