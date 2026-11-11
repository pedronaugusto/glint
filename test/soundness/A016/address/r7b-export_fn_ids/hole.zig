// A016: an exported function (callable from outside the program by its symbol), two identifying parameters of one integer type
export fn link(parent_id: u32, child_id: u32) u32 {
    return parent_id +% child_id;
}
