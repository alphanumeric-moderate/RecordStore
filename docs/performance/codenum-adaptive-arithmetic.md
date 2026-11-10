# CodeNum adaptive arithmetic

CodeNum exposes direct function calls for arithmetic: CodeNum.add, CodeNum.sub, CodeNum.mul, and CodeNum.div. These entry points do not dispatch through operator metamethods. The register variants addInto, subInto, mulInto, and divInto write into a caller-owned register and avoid allocating a new result wrapper.

The precise decimal coefficient backend uses table-based limbs. The exponent representation remains buffer-backed because it has a fixed bounded binary representation; changing it to a table would add object and iteration overhead without a demonstrated benefit.

## Multiplication dispatch

The bounded decimal backend selects among:
- Schoolbook multiplication below 40 limbs.
- Karatsuba multiplication from 40 limbs.
- Toom-Cook-4 from 192 limbs.
- Blocked multiplication for operands with a length ratio greater than 2:1.

Toom-4 evaluates the coefficient polynomials at 0, 1, -1, 2, -2, 3, and infinity, then performs exact integer interpolation. The interpolation denominator is checked for zero remainder and every recovered coefficient is checked for non-negativity before recomposition. Thresholds are conservative initial values and must be retuned from Roblox measurements on target hardware.

## Division

Multi-limb division uses normalized Knuth Algorithm D. It estimates quotient digits from the leading divisor limb using a precomputed reciprocal, then corrects the estimate with exact integer products before the second-limb bound and multiply-subtract/add-back steps. Remainders are unnormalized with exact single-limb division.

The previous implementation binary-searched every quotient limb, allocating a divisor product for each candidate. The new kernel removes that per-digit search and its temporary products. For CodeNum's current 4,096-significant-digit limit, the normalized quadratic kernel is retained rather than importing a recursive division implementation whose overhead may exceed its benefit at the supported operand sizes. Faster reciprocal division can be evaluated separately if the coefficient-size limit is raised.

## Allocation and runtime behavior

A bounded LIFO pool reuses temporary coefficient arrays. It is not used for persistent values, stored decimal strings, or caller-visible state. Coefficient limbs remain tables; existing fixed-size exponent buffers are unchanged. The module requests file-wide Luau native compilation using --!native. This request must be measured in Roblox Studio because the Lune regression runtime does not establish Studio native-code performance.

## Benchmarks

- bench/codenum_multiprecision.bench.luau is the Lune/CodSpeed arithmetic workload and crosses the dispatch thresholds.
- bench/CodeNumAptIntComparison.server.luau is a manual Roblox Studio comparison. Install CodeNum and AptInt as ModuleScripts beneath ReplicatedStorage before running it. Timed sections exclude construction and correctness preflight. It compares equivalent integer workloads only; AptInt does not provide CodeNum's decimal precision, scientific-number, special-number, or expression semantics.

No universal performance superiority is claimed from algorithm names. Treat the Studio comparison on target hardware and native-codegen settings as acceptance evidence.