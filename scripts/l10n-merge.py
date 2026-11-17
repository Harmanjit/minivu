#!/usr/bin/env python3
"""Folds translations into the String Catalogs, so agents never edit a catalog in parallel.

Usage:
  scripts/l10n-merge.py FILE...       merge translation files into the catalogs
  scripts/l10n-merge.py --todo LANG   print LANG's untranslated keys (JSON) to translate
  scripts/l10n-merge.py               rewrite every catalog in sync's format

A translation file is named <lang>.json or <lang>.<anything>.json (de.json,
pt-BR.json, en.browser.json) and holds
  {"Minivu": {"Open in Viewer": "In Viewer öffnen",
              "%lld images": {"one": "%lld Bild", "other": "%lld Bilder"}}}
Each value replaces that language's entry for the key, with the state
needs_review ("translated" for en, the English plural forms). Every key must
already be in the catalog (run scripts/l10n-sync.sh first); otherwise nothing
is written. Catalogs are written as xcstringstool sync writes them.
Protocol: docs/feature-notes/l10n.md, "Working in parallel".
"""
import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TARGETS = ["MinivuCore", "MinivuRender", "Minivu"]
PLURALS = {"de": ["one", "other"], "nl": ["one", "other"], "fr": ["one", "many", "other"],
           "es": ["one", "many", "other"], "it": ["one", "many", "other"], "pt-BR": ["one", "many", "other"],
           "pl": ["one", "few", "many", "other"], "ja": ["other"], "zh-Hans": ["other"], "ko": ["other"],
           "hi": ["one", "other"], "pa": ["one", "other"], "bn": ["one", "other"], "gu": ["one", "other"],
           "ta": ["one", "other"], "en": ["one", "other"]}


def path(target):
    return os.path.join(ROOT, "Sources", target, "Localizable.xcstrings")


def fmt(value, depth=0):
    """JSON as xcstringstool writes it: sorted keys, " : ", empty objects on three lines."""
    pad, end = "  " * (depth + 1), "  " * depth
    if isinstance(value, dict):
        if not value:
            return "{\n\n" + end + "}"
        items = (pad + json.dumps(k, ensure_ascii=False) + " : " + fmt(value[k], depth + 1) for k in sorted(value))
        return "{\n" + ",\n".join(items) + "\n" + end + "}"
    if isinstance(value, list):
        return "[\n" + ",\n".join(pad + fmt(v, depth + 1) for v in value) + "\n" + end + "]"
    return json.dumps(value, ensure_ascii=False)


def load():
    catalogs = {}
    for target in TARGETS:
        with open(path(target), encoding="utf-8") as f:
            catalogs[target] = json.load(f)
    return catalogs


def save(catalogs):
    for target, catalog in catalogs.items():
        with open(path(target), "w", encoding="utf-8") as f:
            f.write(fmt(catalog))


def live(entry):
    return entry.get("extractionState") != "stale" and entry.get("shouldTranslate") is not False


def todo(language):
    out = {}
    for target, catalog in load().items():
        for key, entry in catalog["strings"].items():
            if not live(entry) or language in entry.get("localizations", {}):
                continue
            english = entry.get("localizations", {}).get("en", {})
            plural = english.get("variations", {}).get("plural")
            item = {"english": {c: v["stringUnit"]["value"] for c, v in plural.items()} if plural
                    else english.get("stringUnit", {}).get("value", key)}
            if plural:
                item["categories"] = PLURALS[language]
            if "comment" in entry:
                item["comment"] = entry["comment"]
            out.setdefault(target, {})[key] = item
    print(json.dumps(out, ensure_ascii=False, indent=2))


def merge(files):
    catalogs, problems = load(), []
    for name in files:
        language = os.path.basename(name).split(".")[0]
        if language not in PLURALS:
            problems.append(f"{name}: unknown language {language}")
            continue
        state = "translated" if language == "en" else "needs_review"
        unit = lambda text: {"stringUnit": {"state": state, "value": text}}
        with open(name, encoding="utf-8") as f:
            for target, strings in json.load(f).items():
                if target not in catalogs:
                    problems.append(f"{name}: unknown target {target}")
                    continue
                for key, text in strings.items():
                    entry = catalogs[target]["strings"].get(key)
                    if entry is None or not live(entry):
                        problems.append(f"{name}: {target} has no live key {key!r}")
                    elif isinstance(text, dict):
                        entry.setdefault("localizations", {})[language] = {
                            "variations": {"plural": {c: unit(t) for c, t in text.items()}}}
                    else:
                        entry.setdefault("localizations", {})[language] = unit(text)
    if problems:
        sys.exit("\n".join(problems) + "\nNothing written.")
    save(catalogs)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--todo"] and len(sys.argv) == 3:
        todo(sys.argv[2])
    else:
        merge(sys.argv[1:])
