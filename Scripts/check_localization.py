#!/usr/bin/env python3
"""Check app language coverage, format tokens, and literal localization keys.

Run from any directory with: python3 Scripts/check_localization.py
This is a source/catalog check. It does not identify every UI string or validate
translations supplied by the OS, remote metadata, or bundled HTML documents.
"""
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LANGUAGE_SOURCE = ROOT / 'Packages/MusicFreeUI/Sources/DesignSystem/Localization/MusicFreeLocalization.swift'
LANGUAGES = re.findall(r'case \w+ = "([^"]+)"', LANGUAGE_SOURCE.read_text().split('public var id:')[0])
CATALOG = ROOT / 'Packages/MusicFreeUI/Sources/DesignSystem/Resources/Localizable.xcstrings'
FORMAT = re.compile(r'%(?:\d+\$)?[-+#0 ]*\d*(?:\.\d+)?(?:hh|ll|h|l|z|t|j)?[@diuoxXfFeEgGcCsSpaA%]')
LITERAL = r'"(?:[^"\\]|\\.)*"'
CALL = re.compile(r'\b(?:L|MusicFreeLocalization\.(?:resource|localized))\(\s*(' + LITERAL + r')')
PROPERTY = re.compile(r'var (?:errorDescription|userFacingReason|failureReason|userMessage): String\??\s*\{')
issues = []


def read_catalog(path):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                issues.append(f'{path.relative_to(ROOT)}: duplicate key {key!r}')
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=pairs)['strings']


def units(entry):
    if 'stringUnit' in entry:
        yield entry['stringUnit']
    for name in ('variations', 'substitutions'):
        for child in entry.get(name, {}).values():
            if isinstance(child, dict):
                yield from units(child)
    # Variations contain another level keyed by plural/device category.
    for name, child in entry.items():
        if name not in ('stringUnit', 'variations', 'substitutions') and isinstance(child, dict):
            yield from units(child)


def tokens(value):
    return Counter(token for token in FORMAT.findall(value) if token != '%%')


catalogs = [(CATALOG, read_catalog(CATALOG)), (ROOT / 'App/InfoPlist.xcstrings', read_catalog(ROOT / 'App/InfoPlist.xcstrings'))]
for path, strings in catalogs:
    for key, entry in strings.items():
        localized = entry.get('localizations', {})
        source_units = list(units(localized.get('en', {})))
        for language in LANGUAGES:
            translated = list(units(localized.get(language, {})))
            if not translated:
                issues.append(f'{key!r}: missing {language}')
            for unit in translated:
                value = unit.get('value', '')
                if unit.get('state') != 'translated' or not value.strip():
                    issues.append(f'{key!r}: incomplete {language}')
                if '\\n' in value or '\\(' in value:
                    issues.append(f'{key!r}: literal Swift escape in {language}')
            if len(source_units) == 1 and len(translated) == 1:
                if tokens(source_units[0]['value']) != tokens(translated[0].get('value', '')):
                    issues.append(f'{key!r}: format tokens differ in {language}')
        if '\\n' in key or '\\(' in key:
            issues.append(f'{key!r}: escaped runtime key')
    print(f'{path.relative_to(ROOT)}: {len(strings)} keys; languages: {", ".join(LANGUAGES)}')

strings = catalogs[0][1]
references = 0
files = 0
for root in (ROOT / 'App', ROOT / 'Packages'):
    for path in sorted(root.rglob('*.swift')):
        if any(part in path.parts for part in ('Tests', '.build', '.noindex', 'MusicTestSupport')):
            continue
        files += 1
        text = path.read_text()
        # Skip comments, preserving line numbers for actionable diagnostics.
        text = re.sub(r'/\*[\s\S]*?\*/|(?m:^\s*//[^\n]*)', lambda m: '\n' * m[0].count('\n'), text)
        for match in CALL.finditer(text):
            location = f'{path.relative_to(ROOT)}:{text.count(chr(10), 0, match.start()) + 1}'
            raw = match[1]
            if '\\(' in raw:
                issues.append(f'{location}: interpolated localization key {raw}')
                continue
            try:
                key = json.loads(raw)
            except json.JSONDecodeError:
                issues.append(f'{location}: unsupported Swift escape; inspect {raw}')
                continue
            references += 1
            if key not in strings:
                issues.append(f'{location}: missing key {key!r}')
        # Stable domain error reasons are catalogued for translation by UI.
        for match in PROPERTY.finditer(text):
            start = end = match.end()
            depth = 1
            while end < len(text) and depth:
                depth += (text[end] == '{') - (text[end] == '}')
                end += 1
            for literal in re.finditer(LITERAL, text[start:end]):
                if '\\(' in literal[0]:
                    continue
                key = json.loads(literal[0])
                if ' ' in key and key not in strings:
                    issues.append(f'{path.relative_to(ROOT)}: uncatalogued error reason {key!r}')

# The one conditional key call currently in the app also requires both keys.
for key in ('完成编辑', '编辑歌单'):
    if key not in strings:
        issues.append(f'Missing conditional localization key {key!r}')
print(f'Scanned {files} Swift files and {references} literal localization references.')
for issue in issues:
    print(f'ERROR: {issue}')
print(f'Issues: {len(issues)}')
sys.exit(bool(issues))
