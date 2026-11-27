// The module the case imports as "cmod": compiled as translate-c's output would be, and given
// to glint as external, so glint reads none of it.
pub fn getpid() c_int {
    return 1;
}
