#!/usr/bin/env python3
"""Add compiler-resolved Swift call sites to a pinned Scriv function map."""
import argparse
from collections import defaultdict
import ctypes as ct
import json
from pathlib import Path
import subprocess
import sys
from tempfile import gettempdir, TemporaryDirectory

DEFINITION = 1 << 1
CALL = 1 << 5
DYNAMIC = 1 << 6
IMPLICIT = 1 << 8
RECORD_DEPENDENCY = 2


class IndexString(ct.Structure):
    _fields_ = [('start', ct.c_void_p), ('length', ct.c_size_t)]

    def bytes(self):
        return ct.string_at(self.start, self.length) if self.length else b''


def indexed_occurrences(library, directory, source_root, paths):
    # The IndexStore C API provides the full source path and exact symbol ID.
    # Use the records referenced by compiler units, including when basenames repeat.
    index = ct.CDLL(str(library))
    pointer, integer = ct.c_void_p, ct.c_uint
    handle_visitor = ct.CFUNCTYPE(ct.c_bool, pointer, pointer)
    unit_visitor = ct.CFUNCTYPE(ct.c_bool, pointer, IndexString)

    def api(name, result, *arguments):
        entry = getattr(index, 'indexstore_' + name)
        entry.restype, entry.argtypes = result, arguments
        return entry

    open_store = api('store_create', pointer, ct.c_char_p, pointer)
    close_store = api('store_dispose', None, pointer)
    visit_units = api('store_units_apply_f', ct.c_bool, pointer, integer, pointer, unit_visitor)
    open_unit = api('unit_reader_create', pointer, pointer, ct.c_char_p, pointer)
    close_unit = api('unit_reader_dispose', None, pointer)
    visit_dependencies = api('unit_reader_dependencies_apply_f', ct.c_bool, pointer, pointer, handle_visitor)
    dependency_kind = api('unit_dependency_get_kind', ct.c_int, pointer)
    dependency_path = api('unit_dependency_get_filepath', IndexString, pointer)
    dependency_name = api('unit_dependency_get_name', IndexString, pointer)
    open_record = api('record_reader_create', pointer, pointer, ct.c_char_p, pointer)
    close_record = api('record_reader_dispose', None, pointer)
    visit_occurrences = api('record_reader_occurrences_apply_f', ct.c_bool, pointer, pointer, handle_visitor)
    occurrence_roles = api('occurrence_get_roles', ct.c_uint64, pointer)
    occurrence_symbol = api('occurrence_get_symbol', pointer, pointer)
    occurrence_position = api('occurrence_get_line_col', None, pointer, ct.POINTER(integer), ct.POINTER(integer))
    symbol_identity = api('symbol_get_usr', IndexString, pointer)

    all_units, records, occurrences = [], set(), []
    source_paths = {bytes(source_root / path): path for path in paths}

    @unit_visitor
    def collect_unit(_, name):
        all_units.append(name.bytes())
        return True

    @handle_visitor
    def collect_record(_, dependency):
        if dependency_kind(dependency) == RECORD_DEPENDENCY:
            path = source_paths.get(dependency_path(dependency).bytes())
            if path:
                records.add((path, dependency_name(dependency).bytes()))
        return True

    store = open_store(bytes(directory), None)
    if not store:
        raise ValueError('Cannot open Swift index store.')
    try:
        if not visit_units(store, 1, None, collect_unit):
            raise ValueError('Cannot read Swift index units.')
        for name in all_units:
            unit = open_unit(store, name, None)
            if not unit:
                raise ValueError('Cannot open Swift index unit.')
            try:
                if not visit_dependencies(unit, None, collect_record):
                    raise ValueError('Cannot read Swift unit dependencies.')
            finally:
                close_unit(unit)
        if {path for path, _ in records} != set(paths):
            raise ValueError('Swift index did not produce a source record for each pinned function file.')

        for path, name in sorted(records):
            record = open_record(store, name, None)
            if not record:
                raise ValueError('Cannot open Swift source record.')
            try:
                @handle_visitor
                def collect_occurrence(_, occurrence):
                    roles = occurrence_roles(occurrence)
                    if roles & (DEFINITION | CALL) and not roles & IMPLICIT:
                        symbol = symbol_identity(occurrence_symbol(occurrence)).bytes()
                        line, column = integer(), integer()
                        occurrence_position(occurrence, ct.byref(line), ct.byref(column))
                        if symbol and line.value:
                            occurrences.append((path, line.value, symbol, roles))
                    return True

                if not visit_occurrences(record, None, collect_occurrence):
                    raise ValueError('Cannot read Swift source occurrences.')
            finally:
                close_record(record)
    finally:
        close_store(store)
    return occurrences


def resolve_calls(ranges, occurrences):
    definitions = defaultdict(set)
    call_sites = set()
    for path, line, symbol, roles in occurrences:
        if roles & DEFINITION:
            boundaries = [end for start, end in ranges[path] if start == line]
            if len(boundaries) == 1:
                definitions[symbol].add((path, line, boundaries[0]))
        if roles & CALL and not roles & DYNAMIC and any(start <= line <= end for start, end in ranges[path]):
            call_sites.add((path, line, symbol))

    resolved = set()
    for path, line, symbol in call_sites:
        destinations = definitions.get(symbol, ())
        if len(destinations) == 1:
            target, start, end = next(iter(destinations))
            if target != path or not start <= line <= end:
                resolved.add((path, line, target, start, end))
    return [{'caller': {'path': path, 'line': line}, 'callee': {'path': target, 'start': start, 'end': end}}
            for path, line, target, start, end in sorted(resolved)]


def index_sources(root, directory, sources, function_paths):
    sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
    compiler = Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip())
    library = compiler.parent.parent / 'lib/libIndexStore.dylib'
    support = sdk / 'System/iOSSupport'
    common = [compiler, '-frontend', '-swift-version', '5', '-sdk', sdk, '-O',
              '-target', 'arm64-apple-ios17.0-macabi', '-Fsystem', support / 'System/Library/Frameworks',
              '-I', support / 'usr/lib/swift', '-index-ignore-clang-modules', '-index-ignore-stdlib',
              '-index-include-locals']
    core = sorted(path for path in sources if path.startswith('apps/mac/Sources/ScrivCore/') and path.endswith('.swift'))
    app = sorted(set(function_paths).difference(core) | {
        path for path in sources if path.endswith('.swift')
        and path.startswith(('apps/catalyst/ScrivUIKit/', 'apps/catalyst/MacRuntimeBridge/'))})
    header = 'apps/catalyst/CLIInstrumentation/ScrivCLICoverageBridge.h'
    if not core or not app or header not in sources:
        raise ValueError('Pinned Scriv Core, UIKit and coverage bridge sources are required.')

    def compile_index(module, paths, *arguments):
        index = directory / module
        outputs = directory / (module + '.filelist')
        outputs.write_text(''.join(str(directory / (module + '-' + str(i) + '.o')) + '\n' for i in range(len(paths))))
        with TemporaryDirectory(dir=directory, prefix=module + '-cache-') as cache:
            command = [*common, '-module-cache-path', cache, '-module-name', module, *arguments]
            inputs = [root / path for path in paths]
            if module == 'ScrivCore':
                # Typechecking with the per-file index outputs is separate from
                # emitting the single module imported by the UIKit target.
                subprocess.run([*command, '-emit-module', '-o', directory / 'ScrivCore.swiftmodule', *inputs],
                               check=True, stdout=sys.stderr)
            subprocess.run([*command, '-typecheck', '-index-store-path', index,
                            '-index-unit-output-path-filelist', outputs, *inputs], check=True, stdout=sys.stderr)
        return indexed_occurrences(library, index, root, set(paths) & set(function_paths))

    core_index = compile_index('ScrivCore', core, '-parse-as-library')
    app_index = compile_index('ScrivUIKit', app, '-D', 'SCRIV_CLI_AUTOMATION', '-D', 'SCRIV_CLI_COVERAGE',
                              '-Xcc', '-DSCRIV_CLI_AUTOMATION', '-Xcc', '-DSCRIV_CLI_COVERAGE',
                              '-import-objc-header', root / header, '-I', directory)
    return core_index + app_index


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', required=True, type=Path, help='Original producer source tree')
    parser.add_argument('--source-manifest', required=True, type=Path, help='Original coverage build-source manifest')
    parser.add_argument('--functions', required=True, type=Path, help='Function map from the signed reference capture')
    parser.add_argument('--scratch-directory', type=Path, help='External parent for temporary compiler data')
    args = parser.parse_args()
    root = args.source_root.resolve(strict=True)
    scratch = (args.scratch_directory or Path(gettempdir())).resolve(strict=True)
    if scratch.is_relative_to(root):
        raise ValueError('Temporary compiler data must be outside source.')

    functions = json.loads(args.functions.read_bytes())
    if functions.get('kind') != 'llvm-function-map' or functions.get('version') != 1 or 'calls' in functions:
        raise ValueError('Provide an original version-1 compiler function map.')
    module = Path(__file__).with_name('export-cli-source-manifest.mjs').resolve().as_uri()
    manifest = args.source_manifest.resolve(strict=True)

    def verify_source():
        subprocess.run(['node', '--input-type=module', '-e',
                        'const {verifySourceManifest} = await import(process.argv[1]);'
                        'await verifySourceManifest(process.argv[2], process.argv[3], process.argv[4]);',
                        module, root, manifest, functions['sourceManifestSha256']], check=True, capture_output=True)

    verify_source()
    sources = {entry['path']: entry['sha256'] for entry in json.loads(manifest.read_bytes())['files']}
    ranges = {}
    for row in functions['files']:
        path = row['path']
        if not path.endswith('.swift') or path in ranges or sources.get(path) != row['sha256']:
            raise ValueError('Function file does not match the pinned source.')
        ranges[path] = row['ranges']

    with TemporaryDirectory(dir=scratch, prefix='scriv-call-index-') as directory:
        occurrences = index_sources(root, Path(directory), sources, ranges)
    verify_source()
    functions['calls'] = resolve_calls(ranges, occurrences)
    print(json.dumps(functions, separators=(',', ':')))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Could not export compiler call map from the pinned source ({type(error).__name__}).', file=sys.stderr)
        sys.exit(2)
