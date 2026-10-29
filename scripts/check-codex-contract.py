#!/usr/bin/env python3
"""Validate Scriv's JSON fixtures against locally generated Codex app-server schemas.

Dependency: jsonschema==4.25.1 (verification only).
This script does not launch Codex or send requests to a server.
See docs/codex-integration.md for reproducible schema-generation commands.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

try:
    from jsonschema import Draft7Validator
except ImportError:
    sys.exit("Missing verification dependency: install jsonschema==4.25.1 in a Python virtual environment.")


def local_references_only(value: object) -> None:
    """Generated schemas are self-contained. Never fetch a remote schema reference."""
    if isinstance(value, dict):
        reference = value.get("$ref")
        if isinstance(reference, str) and not reference.startswith("#"):
            raise ValueError(f"Schema has an external reference: {reference}")
        for child in value.values():
            local_references_only(child)
    elif isinstance(value, list):
        for child in value:
            local_references_only(child)


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("schema_dir", type=Path, help="Directory produced by codex app-server generate-json-schema")
    parser.add_argument("--fixtures", type=Path, default=repository / "tests/fixtures/codex-0.165.0.json")
    parser.add_argument("--report", type=Path, help="Optional destination for a JSON verification result")
    args = parser.parse_args()

    try:
        catalog = json.loads(args.fixtures.read_text(encoding="utf-8"))
        fixtures = catalog["fixtures"]
        if not isinstance(fixtures, list) or not fixtures:
            raise ValueError("The fixture catalog must contain a nonempty fixtures array.")
        schemas: dict[str, Draft7Validator] = {}
        results: list[dict[str, object]] = []
        root = args.schema_dir.resolve(strict=True)
        for fixture in fixtures:
            name, filename, payload = fixture["name"], fixture["schema"], fixture["payload"]
            expected_valid = fixture.get("expectedValid", True)
            if not isinstance(expected_valid, bool):
                raise ValueError(f"Fixture {name} expectedValid must be a boolean.")
            if filename not in schemas:
                source = (root / filename).resolve(strict=True)
                if not source.is_relative_to(root):
                    raise ValueError(f"Schema path leaves the generated schema directory: {filename}")
                schema = json.loads(source.read_text(encoding="utf-8"))
                local_references_only(schema)
                Draft7Validator.check_schema(schema)
                schemas[filename] = Draft7Validator(schema)
            errors = list(schemas[filename].iter_errors(payload))
            passed = (not errors) == expected_valid
            result: dict[str, object] = {"name": name, "schema": filename, "passed": passed}
            if not expected_valid:
                result["negative"] = True
            if not passed:
                result["errors"] = [error.message[:500] for error in errors] or ["The schema unexpectedly accepted this invalid regression fixture."]
            results.append(result)
            print(f"{'PASS' if passed else 'FAIL'}  {name}")

        report = {
            "fixtureRuntime": catalog["runtime"],
            "schemaDirectory": str(root),
            "schemaVersionIndependentlyVerified": False,
            "authenticated": False,
            "generationRun": False,
            "results": results,
        }
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        count = sum(result["passed"] is True for result in results)
        print(f"{count}/{len(results)} contract checks passed.")
        return 0 if count == len(results) else 1
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Contract verification could not run: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
