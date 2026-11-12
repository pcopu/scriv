#!/usr/bin/env python3
"""Static migration ledger. Does not execute tests, launch Scriv, or certify parity."""
import argparse
import ast
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess

BASELINE = '4d14b29f4fb49891e850fa9a8e5742dc878603c8'
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/testing/cli-migration-inventory.json'


def balanced(text, start):
    """Read a balanced JS call/array, preserving quoted expressions."""
    pairs = {'(': ')', '[': ']', '{': '}'}
    stack = []
    quote = None
    escaped = False
    for i in range(start, len(text)):
        c = text[i]
        if quote:
            if escaped:
                escaped = False
            elif c == '\\':
                escaped = True
            elif c == quote:
                quote = None
            continue
        if c in "'\"`":
            quote = c
        elif c in pairs:
            stack.append(pairs[c])
        elif stack and c == stack[-1]:
            stack.pop()
            if not stack:
                return text[start + 1:i], i + 1
    raise ValueError('Unbalanced expression near ' + text[start:start + 80])


def split_rows(text):
    result, start, i = [], 0, 0
    while i < len(text):
        if text[i] in '[({':
            _, i = balanced(text, i)
        elif text[i] in "'\"`":
            quote = text[i]
            i += 1
            while i < len(text):
                if text[i] == '\\':
                    i += 2
                elif text[i] == quote:
                    i += 1
                    break
                else:
                    i += 1
        elif text[i] == ',':
            result.append(text[start:i].strip())
            start = i = i + 1
        else:
            i += 1
    if text[start:].strip():
        result.append(text[start:].strip())
    return result


def suite(path):
    if path.startswith('cloud/'):
        return 'cloud-vitest'
    if path.startswith('apps/catalyst/Tests/'):
        return 'catalyst-xctest'
    if path.startswith('apps/mac/Tests/'):
        return 'swift-package-tests'
    if path.startswith('apps/runtime-bridge/'):
        return 'runtime-bridge-xctest'
    if path.endswith('.selfcheck.swift'):
        return 'standalone-swift-selfcheck'
    if path.endswith('.m'):
        return 'native-objective-c-policy'
    if path.endswith('.py') and '/tests/' in path:
        return 'updates-python-unittest'
    if path.endswith('.mjs') and ('/tests/' in path or path.startswith('tests/')):
        return 'node-tests'
    return 'verification-script'


def discover():
    # Track the pre-existing test surface, not new untracked migration tests.
    paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', BASELINE], cwd=ROOT, text=True).splitlines()
    files, tests, assertions, stages = [], [], [], []
    for path in paths:
        p = ROOT / path
        is_test = (path.startswith('tests/') or '/Tests/' in path or '/tests/' in path)
        is_script = (path.startswith('scripts/') and re.search(r'/(?:check-|verify|smoke-|test-|profile-)', path)) or path == 'updates/scripts/verify_staged.py'
        if not (is_test or is_script) or p.suffix not in {'.swift', '.mjs', '.ts', '.py', '.sh', '.m'}:
            continue
        source = subprocess.check_output(['git', 'show', BASELINE + ':' + path], cwd=ROOT, text=True)
        group = suite(path)
        entries = []
        if p.suffix in {'.mjs', '.ts'} and is_test:
            pattern = r'(?m)^\s*(?:await\s+)?(?:test|it)(?:\.(?:each|skipIf|runIf|only|skip|todo))?\s*\('
            for match in re.finditer(pattern, source):
                call = match.group().strip()
                opening = source.index('(', match.start())
                args = source[opening + 1:]
                end = opening + 1
                rows = None
                condition = None
                if any('.' + v in call for v in ('each', 'skipIf', 'runIf')):
                    params, end = balanced(source, opening)
                    start = end
                    while source[start].isspace():
                        start += 1
                    if source[start] != '(':
                        raise ValueError(f'Unrecognized test registration: {path}:{start}')
                    args = source[start + 1:]
                    if '.each' in call and params.strip().startswith('['):
                        row_text, _ = balanced(params.strip(), 0)
                        rows = split_rows(row_text)
                    else:
                        condition = params
                title = re.match(r'''\s*(['"`])((?:\\.|(?!\1).)*?)\1''', args, re.S)
                name = title.group(2) if title else args.splitlines()[0][:160]
                for index, row in enumerate(rows or [None]):
                    entries.append({'name': name, 'line': source.count('\n', 0, match.end() - len(match.group().lstrip())) + 1,
                                    'parameter_row': index + 1 if rows else None, 'parameter_expression': row,
                                    'registration': call, 'condition': condition,
                                    'dynamic_title': bool(title and title.group(1) == '`' and '${' in name)})
        elif p.suffix == '.swift':
            for m in re.finditer(r'\bfunc\s+(test\w+)\s*\(', source):
                entries.append({'name': m.group(1), 'line': source.count('\n', 0, m.start()) + 1})
        elif p.suffix == '.py':
            tree = ast.parse(source)
            for node in ast.walk(tree):
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith('test_'):
                    entries.append({'name': node.name, 'line': node.lineno})
        elif p.suffix == '.m':
            for m in re.finditer(r'static\s+BOOL\s+(\w+)\s*\(', source):
                entries.append({'name': m.group(1), 'line': source.count('\n', 0, m.start()) + 1})
        if not entries:
            entries.append({'name': p.name, 'line': 1, 'granularity': 'script-or-fixture-entrypoint',
                            'requires_manual_review': True})
        for n, entry in enumerate(entries, 1):
            entry.update({'id': f'{path}::{n:04}', 'source': path, 'suite': group,
                          'migration_status': 'unmigrated', 'replacement_scenarios': [],
                          'actual_app_evidence': [], 'retirement_allowed': False})
            tests.append(entry)
        for line, value in enumerate(source.splitlines(), 1):
            stripped = value.strip()
            if stripped.startswith(('//', '#')):
                continue
            if re.search(r'\b(?:XCT\w+|assert(?:\w+)?|expect|precondition(?:Failure)?|REQUIRE|require|self\.assert\w+)\s*[.(]|\braise\s+(?:AssertionError|ValueError|RuntimeError)|throw new Error', value):
                assertions.append({'source': path, 'line': line, 'expression': stripped,
                                   'migration_status': 'unmigrated'})
            if p.suffix == '.sh' and stripped:
                stages.append({'source': path, 'line': line, 'source_text': stripped,
                               'migration_status': 'unmigrated', 'kind': 'shell-source-line-review-required'})
        files.append({'path': path, 'sha256': hashlib.sha256(source.encode()).hexdigest(), 'suite': group,
                      'inventory_entries': len(entries), 'migration_status': 'unmigrated'})
    return files, tests, assertions, stages, paths


def interface_inventory(paths):
    sites = []
    # Each occurrence, not just each line: multiple buttons can share a source line.
    pattern = re.compile(r'\bUIAction\s*[{(]|\bUIKeyCommand\s*\(|#selector\s*\(|\b\w*GestureRecognizer\s*\(|\.button\s*\(|\.addAction\s*\(|\.addTarget\s*\(|accessibilityIdentifier\s*=|\bfunc\s+(?:textView|textField|tableView|collectionView|documentPicker|dropInteraction|dragInteraction)\s*\(')
    for path in paths:
        if not path.startswith('apps/catalyst/ScrivUIKit/') or not path.endswith('.swift'):
            continue
        source = subprocess.check_output(['git', 'show', BASELINE + ':' + path], cwd=ROOT, text=True)
        for number, match in enumerate(pattern.finditer(source), 1):
            start = source.rfind('\n', 0, match.start()) + 1
            end = source.find('\n', match.end())
            sites.append({'id': f'{path}::ui-site-{number:04}', 'source': path,
                          'line': source.count('\n', 0, match.start()) + 1,
                          'kind': match.group().strip(), 'source_text': source[start:end if end >= 0 else None].strip(),
                          'status': 'unverified-candidate', 'cli_command': None,
                          'actual_app_evidence': []})
    return sites


def build():
    files, tests, assertions, stages, paths = discover()
    sites = interface_inventory(paths)
    return {'schema_version': 1,
            'baseline_commit': BASELINE,
            'generator': 'python3 scripts/inventory-cli-migration.py --write',
            'scope': 'Tracked pre-existing test declarations, parameter rows, script entrypoints, assertion source lines and UIKit interaction candidates. No execution or parity certification.',
            'counting_notes': [
                'inventory_entries include named test declarations and expanded literal it.each rows; files without declarations get one script/fixture entrypoint.',
                'Loops, subTest branches and runtime-generated registrations are not exhaustively expanded. Assertion-site records preserve their source lines for manual migration review.',
                'UI sites include helper definitions, duplicate selectors and accessibility metadata. They are review candidates, not a count of distinct user actions.',
                'Static regex inventory is a baseline, not proof of complete runtime test discovery or complete UI action discovery.',
                'All source is read from the frozen baseline commit; later commits, working-tree changes and new CLI tests are excluded.'],
            'summary': {'files': len(files), 'inventory_entries': len(tests),
                        'entries_by_suite': dict(sorted(Counter(t['suite'] for t in tests).items())),
                        'assertion_source_lines': len(assertions), 'shell_review_lines': len(stages),
                        'ui_candidate_sites': len(sites), 'verified_migrated_entries': 0,
                        'verified_ui_parity_actions': 0, 'retirement_allowed': False},
            'files': files, 'tests': tests, 'assertion_sites': assertions,
            'shell_review_sites': stages, 'ui_candidates': sites}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--check', action='store_true', help='Validate the frozen baseline (the default)')
    mode.add_argument('--write', action='store_true', help='Create a missing baseline; never overwrite differing existing content')
    args = parser.parse_args()
    rendered = json.dumps(build(), indent=2, ensure_ascii=False) + '\n'
    if OUT.exists():
        if OUT.read_text() != rendered:
            raise SystemExit('FAIL: inventory differs from its frozen baseline. Refusing to overwrite statuses or evidence. Review the diff and generator changes manually.')
    elif args.write:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(rendered)
    else:
        raise SystemExit('FAIL: inventory is missing. Create it with --write.')
    print('PASS: static migration inventory matches frozen baseline; this does not certify app coverage.')


if __name__ == '__main__':
    main()
