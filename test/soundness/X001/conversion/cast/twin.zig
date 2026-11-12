// governed: the package's maker of the id is no finding.
const module = @import("module");

pub fn f() module.Id {
    return .first();
}
