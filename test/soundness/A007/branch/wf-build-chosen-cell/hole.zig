// warp-fast: a container var whose type a constant chooses: a plain integer or nothing.
const tracing = true;
var hook: if (tracing) u32 else void = if (tracing) 0 else {};
