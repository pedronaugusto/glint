// P007: global assembly defines machine code Zig does not check (review 8, m1).
comptime {
    asm (
        \\.globl glint_probe_ret
        \\glint_probe_ret:
        \\ ret
    );
}
