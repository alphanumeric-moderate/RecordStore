#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

DIAGNOSTIC = re.compile(
    r"^(?P<path>.+?):(?P<line>[0-9]+)\.(?P<column>[0-9]+)-"
    r"(?P<end_line>[0-9]+)\.(?P<end_column>[0-9]+): "
    r"(?P<kind>[^:]+): (?P<message>.*)$"
)
EXPECTATIONS = {"pass", "type-error", "known-type-error"}


def resolve_inside(root: Path, value: str, label: str) -> Path:
    candidate = (root / value).resolve()
    if not candidate.is_relative_to(root):
        raise ValueError(f"{label} escapes the repository root: {value}")
    if not candidate.is_file():
        raise ValueError(f"{label} does not exist or is not a file: {value}")
    return candidate


def parse_diagnostics(output: str) -> list[dict[str, Any]]:
    diagnostics: list[dict[str, Any]] = []
    for raw_line in output.splitlines():
        match = DIAGNOSTIC.match(raw_line)
        if match is None:
            continue
        item = match.groupdict()
        item["line"] = int(item["line"])
        item["column"] = int(item["column"])
        item["end_line"] = int(item["end_line"])
        item["end_column"] = int(item["end_column"])
        diagnostics.append(item)
    return diagnostics


def run_fixture(
    root: Path,
    analyzer: Path,
    definitions: Path,
    datamodel_sourcemap: Path,
    fixture: dict[str, Any],
) -> dict[str, Any]:
    fixture_id = fixture["id"]
    source = resolve_inside(root, fixture["source"], f"{fixture_id} source")
    expectation = fixture["expect"]
    if expectation not in EXPECTATIONS:
        raise ValueError(f"{fixture_id}: unsupported expectation {expectation!r}")

    command = [
        str(analyzer),
        "analyze",
        "--formatter=gnu",
        "--platform=roblox",
        f"--definitions={definitions}",
    ]

    if fixture.get("settings"):
        settings = resolve_inside(root, fixture["settings"], f"{fixture_id} settings")
        command.append(f"--settings={settings}")

    if fixture.get("sourcemap") == "datamodel":
        command.append(f"--sourcemap={datamodel_sourcemap}")
    elif fixture.get("sourcemap") is not None:
        raise ValueError(f"{fixture_id}: unsupported sourcemap selector")

    command.append(str(source))

    completed = subprocess.run(
        command,
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
        check=False,
    )
    output = completed.stdout + completed.stderr
    diagnostics = parse_diagnostics(output)
    type_errors = [item for item in diagnostics if item["kind"] == "TypeError"]
    syntax_errors = [item for item in diagnostics if item["kind"] == "SyntaxError"]
    expected_line = fixture.get("line")
    at_expected_line = (
        [item for item in type_errors if item["line"] == expected_line]
        if expected_line is not None
        else []
    )

    result: dict[str, Any] = {
        "id": fixture_id,
        "source": str(source.relative_to(root)),
        "expectation": expectation,
        "expected_line": expected_line,
        "exit_code": completed.returncode,
        "diagnostics": diagnostics,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
        "command": command,
        "issue": fixture.get("issue"),
    }

    if expectation == "pass":
        passed = completed.returncode == 0 and not diagnostics
        result["status"] = "PASS" if passed else "FAIL"
        if not passed:
            result["reason"] = "valid fixture did not analyze cleanly"
    elif expectation == "type-error":
        passed = completed.returncode != 0 and bool(at_expected_line)
        result["status"] = "PASS" if passed else "FAIL"
        if not passed:
            result["reason"] = "expected a TypeError on the manifest line"
    else:
        expected_failure_observed = completed.returncode != 0 and bool(at_expected_line)
        if expected_failure_observed and not syntax_errors:
            result["status"] = "XFAIL"
        else:
            result["status"] = "XPASS" if completed.returncode == 0 else "FAIL"
            result["reason"] = (
                "upstream reproduction no longer fails; review issue status and update the manifest"
                if completed.returncode == 0
                else "expected solver diagnostic was absent, moved, or became a syntax error"
            )

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Run deterministic Luau analyzer calibration fixtures.")
    parser.add_argument("--luau-lsp", required=True, type=Path)
    parser.add_argument("--definitions", required=True, type=Path)
    parser.add_argument("--datamodel-sourcemap", required=True, type=Path)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("typecheck/fixtures/manifest.json"),
    )
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()

    root = Path.cwd().resolve()
    analyzer = args.luau_lsp.resolve()
    definitions = args.definitions.resolve()
    datamodel_sourcemap = args.datamodel_sourcemap.resolve()
    manifest_path = resolve_inside(root, str(args.manifest), "manifest")

    for label, path in (
        ("luau-lsp executable", analyzer),
        ("Roblox definitions", definitions),
        ("DataModel sourcemap", datamodel_sourcemap),
    ):
        if not path.is_file():
            print(f"ERROR: {label} not found: {path}", file=sys.stderr)
            return 2

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest.get("schemaVersion") != 1:
            raise ValueError("unsupported manifest schemaVersion")
        fixtures = manifest.get("fixtures")
        if not isinstance(fixtures, list) or not fixtures:
            raise ValueError("manifest fixtures must be a non-empty array")

        seen: set[str] = set()
        for fixture in fixtures:
            if not isinstance(fixture, dict):
                raise ValueError("each fixture must be an object")
            fixture_id = fixture.get("id")
            if not isinstance(fixture_id, str) or not fixture_id:
                raise ValueError("each fixture requires a non-empty id")
            if fixture_id in seen:
                raise ValueError(f"duplicate fixture id: {fixture_id}")
            seen.add(fixture_id)
            if not isinstance(fixture.get("source"), str):
                raise ValueError(f"{fixture_id}: source must be a path string")
            if "line" in fixture and (
                not isinstance(fixture["line"], int) or fixture["line"] < 1
            ):
                raise ValueError(f"{fixture_id}: line must be a positive integer")

        results = []
        for fixture in fixtures:
            try:
                result = run_fixture(
                    root,
                    analyzer,
                    definitions,
                    datamodel_sourcemap,
                    fixture,
                )
            except (OSError, subprocess.TimeoutExpired, ValueError) as error:
                result = {
                    "id": fixture.get("id", "<unknown>"),
                    "status": "FAIL",
                    "reason": str(error),
                }
            results.append(result)
            reason = f": {result['reason']}" if result.get("reason") else ""
            issue = f" [{result['issue']}]" if result.get("issue") else ""
            print(f"[{result['status']}] {result['id']}{issue}{reason}")
            if result["status"] in {"FAIL", "XPASS"}:
                diagnostic_output = result.get("stdout", "") + result.get("stderr", "")
                if diagnostic_output:
                    print(diagnostic_output.rstrip())

        summary = {
            "schemaVersion": 1,
            "fixtureCount": len(results),
            "passed": sum(item["status"] == "PASS" for item in results),
            "expectedFailures": sum(item["status"] == "XFAIL" for item in results),
            "failed": sum(item["status"] in {"FAIL", "XPASS"} for item in results),
            "results": results,
        }

        if args.report:
            report_path = args.report.resolve()
            report_path.parent.mkdir(parents=True, exist_ok=True)
            report_path.write_text(
                json.dumps(summary, indent=2) + "\n",
                encoding="utf-8",
            )

        print(
            "Summary: "
            f"{summary['passed']} passed, "
            f"{summary['expectedFailures']} known solver failures, "
            f"{summary['failed']} failed"
        )
        return 1 if summary["failed"] else 0
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
