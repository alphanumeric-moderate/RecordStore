# CodeNum Multiprecision Precision Implementation Plan

> **For agentic workers:** Execute this plan task by task with the test-driven-development workflow. Each step has a checkable result.

**Goal:** Extend CodeNum with bounded, exact decimal significands and configurable decimal arithmetic while preserving the existing native-number and Wide fast paths.

**Architecture:** Add an immutable `Precise` value represented by a signed decimal coefficient and the existing exact base-10 exponent representation. Keep coefficient state private in a weak-key map, reuse the current exponent arithmetic, and extend the existing register state with a precise-value variant. No additional runtime ModuleScripts or third-party dependencies.

**Tech Stack:** Luau strict mode, Roblox `buffer`, Lune regression runners, existing Rojo and GitHub Actions configuration.

**Spec:** This plan is the specification for the CodeNum 0.6.0 precision extension.

## Global Constraints

- Preserve CodeNum's existing native-number and `Wide` behavior and the CN1 decoder.
- Keep all runtime CodeNum implementation in `src/CodeNum/init.luau`.
- Do not introduce runtime `require()` dependencies or third-party libraries.
- Limit exact decimal coefficients to 4096 significant digits and keep the existing exponent magnitude limit of 10^308.
- Use decimal round-half-to-even when a precision context truncates a coefficient.
- Use a default of 34 significant digits for division; addition and multiplication inherit the minimum operand precision unless overridden.
- Do not claim arbitrary binary floating-point precision. Native-number inputs are converted through their shortest round-trippable decimal representation.
- Precision arithmetic must not mutate operands or register input values.
- CN2 precise payloads must be accepted without changing the CodeNumValue JSON envelope version; CN1 remains readable.
- Preserve the existing conservative serialized payload size limit.

## Review Focus

- Carry across the configured precision (for example, 999 rounded to two significant digits) must normalize both the coefficient and exponent correctly.
- Cancellation and mixed signs must not produce a negative zero or corrupt the selected decimal exponent.
- Very distant exponents must not allocate unbounded alignment strings; insignificant operands must be discarded only when they cannot affect the requested precision.
- Division by positive and negative zero, zero divided by zero, and exact halfway rounding must have deterministic behavior.
- Reusing a register as both an input and destination must not mutate a precise operand or invalidate a stored value.

---

## Follow-up correctness hardening

- Precise values carry a private rounding-provenance bit. `CodeNum.wasRounded` exposes it to migration code; the bit is runtime-only and is not part of the CN2 wire format.
- Legacy arithmetic migration rejects rounded operands and results, then checks the legacy result against an unrounded 4096-significant-digit CodeNum calculation. An inexact nested child prevents parent migration. The original serialized legacy payload is retained whenever exactness cannot be demonstrated.
- Legacy exponent conversions are validated before passing them to native `pow` or hyperoperation paths. An integer that changes during binary64 conversion is never used as the migrated exponent.
- Mixed precise multiplication and division preserve the sign of zero. IEEE NaN/infinity dispatch and division by signed zero remain handled by the pre-existing special-number paths and are covered by regressions.
- Additional regression coverage exercises repeating division, coefficient overflow, binary64 arithmetic drift, exact and inexact logarithms, signed zero, mixed special values, half-even division ties, mixed-sign cancellation, and very distant exponents.
### Task 1: Precise value representation, parser, ordering, formatting, and codec

**Files:**
- Modify: `src/CodeNum/init.luau`
- Modify: `bench/run_codenum_regression_tests.luau`

**Interfaces:**
- Add `Precise` to `Value`.
- Add `CodeNum.parse(text: string, precision: number?): Value`.
- Add `CodeNum.fromInteger(text: string, precision: number?): Value`.
- Add `CodeNum.withPrecision(value: Operand, precision: number): Value`.
- Add `CodeNum.isPrecise(value: Operand): boolean`.
- Expose `MAX_PRECISE_DIGITS = 4096` and `DEFAULT_DIVISION_PRECISION = 34`.
- Encode precise values as `CN2|P|<sign>|<digits>|<exponent>|<precision>`; continue decoding CN1 unchanged.

- [x] **Step 1: Add RED regression cases** for exact integers beyond 2^53-1, 18+ digit decimals, explicit precision, round-half-even, compare/sign/abs, exact string output, CN2 round trips, invalid precision, and the 4096-digit boundary.
- [x] **Step 2: Run** `lune run bench/run_codenum_regression_tests.luau` on the test-only commit and confirm the new API assertions fail against the current 0.5.0 source.
- [x] **Step 3: Implement** the private precise-state representation, decimal parsing and canonical normalization without changing the existing native/Wide constructors.
- [x] **Step 4: Implement** precise comparison, sign, absolute value, toString, toNumber/log10 conversion, CN2 encode/decode, and register read/write support.
- [x] **Step 5: Run** the focused Lune regression and confirm the precision representation cases pass.

### Task 2: Configurable precise arithmetic and register operations

**Files:**
- Modify: `src/CodeNum/init.luau`
- Modify: `bench/run_codenum_regression_tests.luau`

**Interfaces:**
- Add optional precision to `add`, `sub`, `mul`, `div`, `pow`, `addInto`, `subInto`, `mulInto`, and `divInto`.
- Addition/subtraction align decimal coefficients with bounded temporary storage.
- Multiplication uses base-10^7 coefficient limbs and rounds to the selected context.
- Division uses integer long division and round-half-to-even.
- Precise values support integer powers up to the existing 1,000,000 exponent limit. Fractional powers on precise values reject explicitly rather than silently downcasting.

- [x] **Step 1: Add RED cases** for exact add/subtract/multiply, mixed signs, cancellation, distant exponents, division at 34 digits, halfway division rounding, zero division, integer powers, and register aliasing.
- [x] **Step 2: Run** the focused Lune regression and confirm these cases fail before arithmetic implementation.
- [x] **Step 3: Implement** bounded decimal add/subtract/multiply/divide helpers and route only precise/explicit-precision operations through them.
- [x] **Step 4: Implement** immutable precise results in reusable registers; retain existing native/Wide register fast paths.
- [x] **Step 5: Run** focused arithmetic and register regressions.

### Task 3: Persistence, formatting integration, documentation, and verification

**Files:**
- Modify: `src/PlayerDataInitializer/CodeNumValue.luau`
- Modify: `src/PlayerDataInitializer/CodeNumFormatter.luau`
- Modify: `bench/run_codenumvalue_regression_tests.luau`
- Modify: `tests/CodeNumFormattingRegression.server.luau`
- Modify: `README.md`
- Add: `bench/codenum_multiprecision.bench.luau`
- Modify: `codspeed.yml`

**Interfaces:**
- CodeNumValue accepts CN1 and CN2 values and keeps the existing JSON envelope format.
- Legacy CodeNum integer nodes use `fromInteger` so values beyond binary64's exact range can migrate without rounding.
- Formatter recognizes CN1/CN2 strings and precise values.
- Document the API, significant-digit limits, rounding model, conversion limits, and migration compatibility.

- [x] **Step 1: Add RED persistence and formatter tests** for CN2 payloads, exact legacy-integer migration, and formatter input.
- [x] **Step 2: Run** the CodeNumValue Lune regression and confirm CN2 handling fails before adapter changes.
- [x] **Step 3: Implement** adapter/formatter compatibility and update the CodeNum version references to 0.6.0.
- [x] **Step 4: Add** a focused multiprecision CodSpeed scenario that is separate from the existing mixed CodeNum 0.5 benchmark.
- [x] **Step 5: Run** CodeNum and CodeNumValue Lune regression suites, the repository's broader regression suite, and the configured CI type-check/build validations.
- [x] **Step 6: Review** the complete diff for compatibility, arithmetic bounds, aliasing, error handling, and accidental changes to existing fast paths before opening the PR.
