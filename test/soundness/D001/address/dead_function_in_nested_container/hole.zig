// D001: a dead private function in a nested container both of whose holders are used
const Outer = struct {
    const Inner = struct {
        fn neverCalled() u8 {
            return 1;
        }
        pub const value = 2;
    };
};
pub const value = Outer.Inner.value;
