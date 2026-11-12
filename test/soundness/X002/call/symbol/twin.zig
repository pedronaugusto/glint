// replaces .symbol: an extern of another link name is no finding.
extern "c" fn getpid() c_int;

pub fn f() c_int {
    return getpid();
}
