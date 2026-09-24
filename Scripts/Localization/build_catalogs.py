#!/usr/bin/env python3
"""Validate reviewed flat maps and build module-owned String Catalogs.

Source manifest comes from Swift -emit-localized-strings for iOS/macOS,
plus the conditionally compiled visionOS availability message.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
LOCALES = ['de', 'fr', 'it', 'pt-BR', 'es', 'zh-Hans', 'ja', 'ko']
FORMAT = re.compile(r'%(?:(\d+)\$)?([-+#0 ]*\d*(?:\.\d+)?(?:ll|l|z|h)?[@diuoxXfFeEgGcsp])|%%')
PLURALS = {
    '%lld backups stored': ['%lld backup stored', '%lld Backup gespeichert', '%lld sauvegarde enregistrée', '%lld backup salvato', '%lld cópia salva', '%lld copia guardada'],
    '%lld discarded writes': ['%lld discarded write', '%lld verworfener Schreibvorgang', '%lld écriture rejetée', '%lld scrittura scartata', '%lld gravação descartada', '%lld escritura descartada'],
    '%lld languages': ['%lld language', '%lld Sprache', '%lld langue', '%lld lingua', '%lld idioma', '%lld idioma'],
    '%lld requests': ['%lld request', '%lld Anfrage', '%lld requête', '%lld richiesta', '%lld solicitação', '%lld solicitud'],
    '%lld tokens': ['%lld token', '%lld Token', '%lld jeton', '%lld token', '%lld token', '%lld token'],
    'Imported %lld records.': ['Imported %lld record.', '%lld Datensatz importiert.', '%lld enregistrement importé.', 'Importato %lld record.', '%lld registro importado.', 'Se importó %lld registro.'],
    'Keep %lld backups': ['Keep %lld backup', '%lld Backup aufbewahren', 'Conserver %lld sauvegarde', 'Conserva %lld backup', 'Manter %lld cópia', 'Conservar %lld copia'],
}

def signature(value):
    automatic = 0
    result = []
    for match in FORMAT.finditer(value):
        if match.group() == '%%':
            result.append(('percent', '%%'))
            continue
        automatic += 1
        result.append((int(match.group(1) or automatic), match.group(2)))
    return sorted(result, key=lambda item: str(item[0]))

def positional(value):
    matches = [x for x in FORMAT.finditer(value) if x.group() != '%%']
    if len(matches) < 2:
        return value
    index = 0
    def replace(match):
        nonlocal index
        if match.group() == '%%': return '%%'
        index += 1
        return '%' + (match.group(1) or str(index)) + '$' + match.group(2)
    return FORMAT.sub(replace, value)

def unit(value):
    return {'stringUnit': {'state': 'translated', 'value': positional(value)}}

def main():
    manifest = json.loads((HERE / 'source-keys.json').read_text())
    keys = manifest['keys']
    maps = {'en': {key: key for key in keys}}
    for locale in LOCALES:
        mapping = json.loads((HERE / 'translations' / (locale + '.json')).read_text())
        assert set(mapping) == set(keys), (locale, 'source key mismatch')
        for key, value in mapping.items():
            assert signature(key) == signature(value), (locale, key, value, 'placeholder mismatch')
            assert key.count('\n') == value.count('\n'), (locale, key, 'newline mismatch')
            assert key.count('`') == value.count('`'), (locale, key, 'code marker mismatch')
            assert 'LIFTCOACHARG' not in value, (locale, key, 'translation sentinel')
            for pattern in [r'^\s*', r'\s*$']:
                assert re.search(pattern, key).group() == re.search(pattern, value).group(), (locale, key, 'boundary whitespace')
        maps[locale] = mapping
    maps['zh-Hant'] = json.loads((HERE / 'translations/zh-Hant.json').read_text())
    for module, module_keys in manifest['modules'].items():
        strings = {}
        for key in module_keys:
            entry = {'extractionState': 'manual', 'localizations': {}}
            if key in manifest['invariantKeys']:
                entry['shouldTranslate'] = False
            for locale, mapping in maps.items():
                if key not in mapping: continue
                value = mapping[key]
                if key in PLURALS:
                    forms = {'other': unit(value)}
                    if locale in ['en', 'de', 'fr', 'it', 'pt-BR', 'es']:
                        singular = PLURALS[key][['en', 'de', 'fr', 'it', 'pt-BR', 'es'].index(locale)]
                        assert signature(key) == signature(singular)
                        forms['one'] = unit(singular)
                    if locale in ['fr', 'it', 'pt-BR', 'es']:
                        forms['many'] = unit(value)
                    entry['localizations'][locale] = {'variations': {'plural': forms}}
                else:
                    entry['localizations'][locale] = unit(value)
            strings[key] = entry
        catalog = {'sourceLanguage': 'en', 'strings': strings, 'version': '1.0'}
        destination = ROOT / 'Sources' / module / 'Resources/Localizable.xcstrings'
        destination.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')
        print(f'{module}: {len(strings)} keys, English + 8 complete locales, existing Traditional Chinese purchase/chat copy retained')
    print(f'Validated {len(keys)} unique keys, placeholders, newlines, code markers, and 7 plural families.')

if __name__ == '__main__':
    main()
