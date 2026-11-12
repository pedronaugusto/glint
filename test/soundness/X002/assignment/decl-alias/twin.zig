// replaces .decl: an alias of the answer is no finding.
const module = @import("module");
const sync = module.syncFile;

pub fn f() *const @TypeOf(sync) {
    return &sync;
}
