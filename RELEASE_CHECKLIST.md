# Release checklist - TeleScope v0.1.0

Status legend: **[x]** done and verified in the pre-release audit,
**[ ]** open, **[~]** partially done. Items marked *(maintainer)* need a
decision or credentials and were deliberately not done by the audit.

## A. Code (blockers)

- [x] P0-1 tracer mailbox bounded under bursts (gate + async installer + preload) - tests R2
- [x] P1-1 single legacy tracer on OTP 26 - test R1
- [x] P1-2/P1-3 capture survives observer death - tests R3/R4
- [x] P1-4 debug-info backend allowlist - test R6
- [x] P1-5 bounded symbolic evaluation - test R7
- [x] P1-6 sensitive-key false positives (incl. `:otp_app`) - tests
- [x] `mix compile --warnings-as-errors` clean on Elixir 1.15/1.17/1.20
- [x] `mix format --check-formatted` clean

## B. Tests

- [x] Full suite green on Elixir 1.15.8/OTP 26.1.2, 1.17.0/26.1.2, 1.17.0/27.0, 1.20.1/29.0 (`scripts/matrix.sh`)
- [x] Green on `:telemetry` 1.0.0 (1 documented skip), 1.1.0, 1.2.1, 1.3.0, 1.4.3
- [x] Multi-node (`:peer`) test green (`mix test --include peer`)
- [x] No flaky tests in 30 randomized-seed runs
- [~] **CI workflow** `.github/workflows/ci.yml` added *(P1-8)*: test matrix (Elixir 1.15/26, 1.17/27, 1.18/27, 1.19/28, 1.20/29), telemetry 1.0.0-1.3.0, format/docs/hex.build, fresh-Phoenix smoke test. Validated locally: YAML + `actionlint` clean; the `quality`, `telemetry-versions` (1.0.0) and `phoenix-smoke` job scripts executed successfully; the `test` job equals the local matrix. **Not yet run on GitHub** - push and confirm green before publishing (Elixir 1.18/1.19 and OTP 28 were never run locally)
- [x] Mix task integration tests against a generated fixture project *(P2-8)*: `test/integration/cli_test.exs` (exit codes 0/1/2, strict mode, JSON on stdout, `--runtime`), run in CI with `--include integration`
- [x] Diagnostic codes are stable and documented (`DIAGNOSTICS.md`; a test fails if a code is undocumented or renumbered)
- [ ] Umbrella project, OTP 28, Elixir 1.16/1.18/1.19 *(P2-7)*

## C. Packaging (Hex)

- [x] `package/0`: licenses (MIT), links, explicit `files` allowlist
- [x] `mix hex.build` succeeds; package contains only `lib/`, `mix.exs`, docs
- [x] `LICENSE` present (MIT, matches `package.licenses`)
- [x] `CHANGELOG.md`
- [x] `CONTRIBUTING.md`
- [x] Version `0.1.0-rc.1`
- [x] Package name `tele_scope` available on hex.pm (checked: "No package with name tele_scope")
- [x] Only runtime dependency `:telemetry ~> 1.0`; `:ex_doc` dev-only
- [ ] Decide final version: publish `0.1.0-rc.1` first, `0.1.0` after section F *(maintainer)*
- [ ] `mix hex.publish` *(maintainer, needs Hex credentials)*

## D. Documentation

- [x] `mix docs` builds with 0 warnings; modules grouped (API / Runtime (advanced) / Internals (unstable))
- [x] README: install snippet (hex + github), `only: [:dev, :test], runtime: false`, `--serve`, `--app`, compatibility table, telemetry >= 1.1 for failure detection
- [x] LIMITATIONS: trust boundaries, gate bit, single legacy tracer, not-yet-verified list
- [x] BENCHMARKS: min **and** median, tracer budget flagged "at risk", audit before/after mailbox data
- [x] SPIKE_RESULTS annotated as historical
- [ ] Decide public API boundary for 1.0: `@moduledoc false` vs documented stability for `Discovery.*` internals *(P2-5)*
- [ ] Remove or move `spike/` evidence to a separate branch if repository size matters *(maintainer)*

## E. Repository hygiene

- [x] `.gitignore`: `_build`, `deps`, `doc`, `*.tar`, `_build_matrix`, `.elixir_ls`, spike DB files
- [x] Empty directories removed
- [ ] Merge branch `audit`, tag `v0.1.0-rc.1` *(maintainer)*
- [ ] GitHub repository description/topics; issue templates (optional)

## F. Before promoting rc -> 0.1.0

- [ ] CI (`.github/workflows/ci.yml`) green on GitHub, including the combinations never run locally
- [ ] Tracer overhead re-measured on bare metal (BENCHMARKS budget "at risk")
- [x] Static + runtime validation on real open-source Phoenix apps
      (VALIDATION.md): static on hexpm, changelog.com, plausible; runtime on
      hexpm (91.1 %) and changelog.com (100 %), target >= 80 % met; 5 defects
      found and fixed; plausible runtime not run (needs ClickHouse)
- [ ] Re-run `mix telemetry.check --strict` and `--runtime --serve` on a fresh
      `mix phx.new` app with the released package (not a path dependency)
