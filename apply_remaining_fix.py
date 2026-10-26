from pathlib import Path
import re

project_root = Path.cwd()
path = project_root / "lib" / "widgets" / "favorites_view.dart"

if not path.exists():
    print("SKIP: lib/widgets/favorites_view.dart was not found.")
    raise SystemExit(0)

source = path.read_text(encoding="utf-8")
pattern = re.compile(
    r"(?m)^(?P<indent>[ \t]*)(?:cacheExtent|scrollCacheExtent)"
    r"(?P<space>[ \t]*):(?P<after>[ \t]*)"
    r"(?P<value>[+-]?(?:\d+(?:\.\d*)?|\.\d+))"
    r"(?P<trailing>[ \t]*,)",
)

def replacement(match: re.Match[str]) -> str:
    return (
        f"{match.group('indent')}scrollCacheExtent: "
        f"const ScrollCacheExtent.pixels({match.group('value')}),"
    )

updated, count = pattern.subn(replacement, source)
if count:
    path.write_text(updated, encoding="utf-8")
    print(f"Fixed {count} numeric cache extent value(s) in {path}.")
else:
    print(
        "No simple numeric cache extent expression needed fixing in "
        f"{path}. Inspect its scrollCacheExtent argument manually if the analyzer still reports it."
    )
