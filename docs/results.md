# G1 results, 2026-10-08

G0/G1 landed at `34b4447455144ff745158cecfd8135b8692a9ea7`. Its raw evidence now lives in [trials at `f501b66f9679760f5fadd118b95bfb36670a891b`](https://github.com/pedronaugusto/trials/tree/f501b66f9679760f5fadd118b95bfb36670a891b/glint/g1). The relocation manifest verifies every committed payload path and SHA-256: 97 files, 1,013,668 bytes (the handoff described 98); two additional raw regression logs from ci were also moved. Tests, benchmarks, layers and the consumer fixture remain here.

The pinned public sample was 19 repositories, 1,179 Zig files, 20,498,313 bytes. All 19 runs completed; the separate private station sample had parser-invalid source and remained incomplete. G1 preserved 32 compatibility IDs; porting did not admit defaults. Its [counts](https://github.com/pedronaugusto/trials/blob/f501b66f9679760f5fadd118b95bfb36670a891b/glint/g1/rule-inventory.json) and full predecessor differential record remain private.

Final paired ReleaseFast G0/G1 measurements: cold core 791.1/917.1 µs (+15.9%); warm core 475.0/497.3 ns (+4.7%). These costs remain disclosed. Own deterministic benchmark smoke and CLI/output/ownership/rule contracts remain executable; CI compiles benchmark programs and timings stay manual.

G2 still owns orchestration, the public project-rule seam and gantry projection. G3 owns admitted aegis and heuristic escape rules; no verifier is planned. G4 owns family migration and predecessor retirement. The package remains unreleased.
