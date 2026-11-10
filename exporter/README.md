# glint's exporter (WIP: written and reviewed by reading, NEVER COMPILED OR RUN)

Design: the book's designs/glint-compiled-facts.md. This directory is a draft of step 1's exporter side.

- `0.17.0/glint-export.patch`: the patch against zig 0.17.0's source (sha256 of the tarball
  b6c7f1728f043700d6529bac980800792f824256a9d2f1839b3d62beed0b8abd). Seven one-line calls
  (Sema.analyzeBodyInner: `at` at the loop head and `result` at the store; Sema.analyzeCall:
  `callBegin` + deferred `callEnd` on the inline/comptime path; PerThread.analyzeFuncBodyInner:
  `functionBegin` + deferred `functionEnd`; Compilation.update: `flush`), `src/glint_export.zig`,
  and `src/glint_facts_format.zig`, a copy of glint's `src/facts_format.zig`. It applies clean in a
  dry run and its files pass `zig fmt --check`; nothing more is known of it.
- `fixtures/<name>/<name>.zig` + `expect.txt` (a count, a tab, a text: that many lines of the
  dump start with the text). The six programs compile with the stock compiler; the expectations
  were written by reasoning, not from a run.
- `tool/facts_dump.zig`: a facts file as text independent of InternPool numbering, ZIR
  instruction numbers and analysis order. Compiles with the stock compiler.
- `round.sh`: one round for the owner (build the exporter if the patch changed, run every
  fixture twice and once with the variable unset, dump, check). It still points at the
  warp-fast scratch tree (scratch/sema/exporter, scratch/sema/zig-src, scratch/sema/fmt) and
  writes scratch/sema/exporter/out; it is to be moved onto this directory once a round passes.
