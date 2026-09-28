"""One status line per hymn PDF: time, key, sections, warning count and the first warning.

    PYTHONPATH=tools .venv/bin/python tools/check_all.py [hymns/pdf/0204-*.pdf ...]
"""

import glob
import sys
import traceback

from hymnpdf.extract import NoMusicError, extract


def main(paths: list[str]) -> int:
    failing = 0
    for path in paths or sorted(glob.glob("hymns/pdf/*.pdf")):
        name = path.rsplit("/", 1)[-1][:4]
        try:
            s = extract(path)
        except NoMusicError as e:  # nothing to convert, e.g. a licensing notice instead of music
            print(f"{name} SKIP {e}"[:160])
            continue
        except Exception as e:  # report and keep going
            failing += 1
            frame = traceback.extract_tb(e.__traceback__)[-1]
            print(f"{name} CRASH {type(e).__name__}: {e} (at {frame.name}:{frame.lineno})")
            continue
        t, k, w = s["time"], s["key"], s["warnings"]
        failing += bool(w)
        sections = ",".join(f"{x['kind']}{sum('parts' not in l for l in x['lyrics'])}"
                            + "+echo" * any("parts" in l for l in x["lyrics"]) for x in s["sections"])
        status = "ok  " if not w else "WARN"
        print(f"{name} {status} {t['beats']}/{t['beatType']} fifths={k['fifths']:+d} {k['mode']} "
              f"[{sections}] m={len(s['measures'])} warnings={len(w)}" + (f" | {w[0][:100]}" if w else ""))
    print(f"{failing} hymn(s) not clean")
    return 1 if failing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
