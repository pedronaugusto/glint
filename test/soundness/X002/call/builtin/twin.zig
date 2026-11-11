// replaces .builtin: the package's own use of it, inside its answer, is no finding, and the
// answer is none here.
const module = @import("module");

pub fn f(cell: *const module.Atomic(u32)) u32 {
    return cell.load();
}
