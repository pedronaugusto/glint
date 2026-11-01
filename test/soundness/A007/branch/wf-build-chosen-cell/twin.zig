// warp-fast: a container var whose type a constant chooses: aegis Atomic or nothing.
const aegis = @import("aegis");
const tracing = true;
var hook: if (tracing) aegis.Atomic(u32) else void = if (tracing) .init(0) else {};
