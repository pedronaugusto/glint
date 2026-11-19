// P007: a bare @fieldParentPtr, the parent recovered with no check the field pointer was its own
const Node = struct { value: u32, link: u32 };
pub fn owner(link: *u32) *Node {
    return @fieldParentPtr("link", link);
}
