// glint-b: A001 field (name spelled): the same shape made safe, which must stay clean
const Plain = struct { data: u32 };
const name = "\x64ata";
pub fn f(g: *Plain) u32 {
    return @field(g, name);
}
