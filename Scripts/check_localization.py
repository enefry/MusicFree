#!/usr/bin/env python3
"""Check app language coverage, format tokens, and literal localization keys.

Run from any directory with: python3 Scripts/check_localization.py
Checks native UI, plugin presentation data, bundled HTML, and catalog integrity.
OS dialogs, remote metadata, user content, and diagnostic codes are not translated
by this catalog. Static analysis cannot prove every runtime presentation path.
"""
from collections import Counter
from html.parser import HTMLParser
from itertools import product
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
    # Percentages in prose ("100% is mono") are not printf's "% i" token.
    value = re.sub(r'(?<=\d)%(?=\s|[。；，、;,.）)]|$)', '', value)
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
SOURCE_ROOTS = (ROOT / 'App', ROOT / 'Packages', ROOT / 'thirdpart/ExtendsPlugins')


def require_key(key, location):
    if key not in strings:
        issues.append(f'{location}: missing presentation key {key!r}')


for root in SOURCE_ROOTS:
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
        is_ui = any(part in path.parts for part in ('App', 'MusicFreeUI', 'MusicFreeDebugSupport'))
        if is_ui:
            # Includes conditional keys, preset dictionaries, section/status
            # tables, icon options, and companion registrations passed to L later.
            for literal in re.finditer(LITERAL, text):
                if '\\(' in literal[0]:
                    continue
                try:
                    key = json.loads(literal[0])
                except json.JSONDecodeError:
                    continue  # Not a simple Swift string literal.
                if re.search(r'[\u4e00-\u9fff]', key) and key not in ('中文', '日本語'):
                    require_key(key, f'{path.relative_to(ROOT)}:{text.count(chr(10), 0, literal.start()) + 1}')
            # Direct native display assignments must resolve their literals.
            direct = r'(?:\.(?:text|placeholder|accessibilityLabel|accessibilityHint)\s*=|\btitle\s*=|(?:UIAction|UIAlertController|UIBarButtonItem|UIMenu|SettingsNativeRow)\(\s*(?:id:\s*' + LITERAL + r',\s*)?title:|\.setTitle\()\s*(' + LITERAL + r')'
            for match in re.finditer(direct, text):
                key = match[1][1:-1]
                if '\\(' not in key and re.search(r'[a-zA-Z\u4e00-\u9fff]', key):
                    issues.append(f'{path.relative_to(ROOT)}:{text.count(chr(10), 0, match.start()) + 1}: unlocalized UI literal {key!r}')
            if 'Plugin' in path.name or path.name == 'OnlineSourcesViewController.swift':
                for match in re.finditer(r'(?<![\w.])(?:(?:snapshot\.|context\.)?descriptor\.name|field\.title)', text):
                    if not text[:match.start()].rstrip().endswith('L('):
                        issues.append(f'{path.relative_to(ROOT)}:{text.count(chr(10), 0, match.start()) + 1}: unresolved plugin presentation text')
        # Plugin packages stay Foundation-only. Their descriptor values are
        # stable keys resolved at the host's display boundary.
        if any(part in path.parts for part in ('MusicFreeBuiltinDSPPlugins', 'MusicFreeBuiltinDataPlugins',
                                               'MusicFreePluginHostBridge', 'ExtendsPlugins')):
            for declaration in re.finditer(r'(?:\b(?:var|let) descriptor\b|\bfunc descriptor\(|\bvar registrations\b)', text):
                start = text.find('{', declaration.end())
                if start < 0:
                    continue
                end, depth = start + 1, 1
                while end < len(text) and depth:
                    depth += (text[end] == '{') - (text[end] == '}')
                    end += 1
                body = text[start:end]
                for match in re.finditer(r'\b(?:name|title):\s*(' + LITERAL + r')', body):
                    if '\\(' not in match[1]:
                        require_key(json.loads(match[1]), str(path.relative_to(ROOT)))
                # A descriptor may compose a service name and a capability.
                for match in re.finditer(r'name:\s*(\w+)\s*\+\s*\([^?]+\?\s*(' + LITERAL + r')\s*:\s*(' + LITERAL + r')', body):
                    assignment = re.search(r'\blet\s+' + match[1] + r'\s*=[^\n]+\?\s*(' + LITERAL + r')\s*:\s*(' + LITERAL + r')', body)
                    if assignment:
                        for name, suffix in product(assignment.groups(), match.groups()[1:]):
                            require_key(json.loads(name) + json.loads(suffix), str(path.relative_to(ROOT)))
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

# Nonliteral call sites outside the Chinese UI tables.
for key in ('完成编辑', '编辑歌单'):
    if key not in strings:
        issues.append(f'Missing conditional localization key {key!r}')


class DocumentMarkup(HTMLParser):
    def __init__(self):
        super().__init__()
        self.markup = []
        self.technical = []
        self.in_code = False

    def handle_starttag(self, tag, attrs):
        self.markup.append(('start', tag, tuple(sorted(attrs))))
        if tag == 'code' or (tag == 'span' and dict(attrs).get('class') == 'mono'):
            self.in_code = True

    def handle_endtag(self, tag):
        self.markup.append(('end', tag))
        self.in_code = False

    def handle_data(self, text):
        if self.in_code:
            self.technical.append(text.strip())


documents = 0


class DocumentTemplate(HTMLParser):
    # These are code samples and addresses, not prose. New document text must
    # use a catalog placeholder; do not silently treat all English as technical.
    technical_values = {
        'xxxxxxxx.apps.googleusercontent.com', 'console.cloud.google.com',
        'https://www.googleapis.com/auth/drive.readonly', 'win.tools4me.music',
        'CLIENT_ID', 'REVERSED_CLIENT_ID', '1234567890-abcdef.apps.googleusercontent.com',
        'com.googleusercontent.apps.1234567890-abcdef', '…apps.googleusercontent.com', 'drive.readonly'
    }

    def __init__(self, path):
        super().__init__()
        self.path = path.relative_to(ROOT)
        self.ignored = []

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style', 'code'):
            self.ignored.append(tag)
        for name, value in attrs:
            if name in ('aria-label', 'title', 'alt') and value and '{{' not in value:
                issues.append(f'{self.path}:{self.getpos()[0]}: unlocalized HTML attribute {value!r}')

    def handle_endtag(self, tag):
        if self.ignored and tag == self.ignored[-1]:
            self.ignored.pop()

    def handle_data(self, text):
        if self.ignored:
            return
        value = re.sub(r'\{\{[\w.]+\}\}', '', text).strip()
        if value and re.search(r'[a-zA-Z\u4e00-\u9fff]', value) and value not in self.technical_values:
            issues.append(f'{self.path}:{self.getpos()[0]}: unlocalized HTML text {value!r}')


for path in (ROOT / 'Packages/MusicFreeUI/Sources').rglob('*.html'):
    template = path.read_text()
    documents += 1
    for key in re.findall(r'\{\{([\w.]+)\}\}', template):
        if key != 'document.language':
            require_key(key, str(path.relative_to(ROOT)))
    DocumentTemplate(path).feed(template)
for key, entry in strings.items():
    if not key.startswith(('guide.drive.', 'policy.lrclib.')):
        continue
    original = DocumentMarkup()
    original.feed(entry['localizations']['en']['stringUnit']['value'])
    for language in LANGUAGES:
        translated = DocumentMarkup()
        translated.feed(entry['localizations'].get(language, {}).get('stringUnit', {}).get('value', ''))
        if original.markup != translated.markup or original.technical != translated.technical:
            issues.append(f'{key!r}: HTML markup, links or technical values differ in {language}')
print(f'Checked {documents} bundled HTML documents and plugin descriptors, fields and conditional UI keys.')
print(f'Scanned {files} Swift files and {references} literal localization references.')
for issue in issues:
    print(f'ERROR: {issue}')
print(f'Issues: {len(issues)}')
sys.exit(bool(issues))
