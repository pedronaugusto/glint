// matrix A007: a raw atomic in a method of a type a generic makes.
pub fn Flag(comptime T: type) type {
    return struct {
        state: T,
        pub fn set(f: *@This(), value: T) T {
            return @atomicRmw(T, &f.state, .Xchg, value, .acq_rel);
        }
    };
}
