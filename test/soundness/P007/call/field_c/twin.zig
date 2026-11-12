// P007: @field over the program's own namespace.
const own = struct {
    fn pid() c_int {
        return 1;
    }
};
pub fn f() c_int {
    return @field(own, "pid")();
}
