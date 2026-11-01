# Luau type-check and code-generation evaluation fixtures

This corpus calibrates the static-analysis layer used to evaluate generated Luau.

## Run locally

Install the versions pinned by `.github/workflows/luau-typecheck.yml`, fetch the same Roblox global definitions used by CI, then run:

```sh
rojo sourcemap typecheck/fixtures/datamodel.project.json --include-non-scripts --output /tmp/typecheck-datamodel-sourcemap.json
python3 bench/run_luau_typecheck_fixtures.py \
  --luau-lsp "$HOME/.local/bin/luau-lsp" \
  --definitions /tmp/globalTypes.d.luau \
  --datamodel-sourcemap /tmp/typecheck-datamodel-sourcemap.json \
  --report /tmp/luau-typecheck-fixtures.json
```

## Fixture contract

- `pass`: valid strict Luau must produce no analyzer errors.
- `type-error`: a deliberately invalid program must produce a type error on the manifest's exact line.
- `known-type-error`: a pinned upstream solver reproduction must continue to produce a type error at its known line. This is a strict expected failure (XFAIL). If it begins passing, the runner reports XPASS and fails so the issue status and baseline can be reviewed deliberately.

The harness checks diagnostic category and source location, not the complete human-readable diagnostic message. This avoids coupling the corpus to harmless wording changes while still rejecting syntax errors, missing definitions, file-resolution failures, and errors emitted at unrelated locations.

All solver reproductions run with the new solver explicitly enabled. DataModel fixtures use a dedicated Rojo sourcemap and enable strict DataModel diagnostics; otherwise these tests would not prove that DataModel Instance members were actually typed.

## Code-generation evaluation use

Treat each fixture as an analyzer calibration test, not as proof that a generated patch is behaviorally correct. A candidate patch must still pass the repository's existing Lune regressions, Rojo project builds, strict source analysis, and Roblox Studio integration tests. The model must not make a fixture green by changing type mode, inserting broad `any` casts, suppressing diagnostics, weakening the manifest, or editing the harness expectations.

Upstream reproductions are tied to their issue URLs in the manifest. When an issue is fixed upstream, change its expectation from `known-type-error` to `pass` only after confirming the pinned analyzer version reproduces the fixed behavior. Keep the original source form available in git history.
