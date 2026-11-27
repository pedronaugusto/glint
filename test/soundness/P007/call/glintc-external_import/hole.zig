// P007: C reached through translate-c's output, a module glint reads none of: the import is the site
const cmod = @import("cmod");
pub fn pid() c_int {
    return cmod.getpid();
}
