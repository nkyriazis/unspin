# The flow file format

A flow is a plain text file with one event per line. `unspin.sh` writes it and `unspin` draws it, but anything that can append a line to a file can take part. A Python script, a Makefile or a hand-typed `echo` all work.

## Where the file lives

One file per agent session, named after the session id.

```
$UNSPIN_DIR/<session>.log
```

`UNSPIN_DIR` defaults to `$XDG_RUNTIME_DIR/unspin` when that directory exists (most Linux desktops), and to `/tmp/unspin-<uid>` otherwise. The session is `$UNSPIN_SESSION`, else `$CLAUDE_CODE_SESSION_ID`, else `default`. Once `unspin.sh` is sourced, `$UNSPIN_FILE` holds the full path and is exported to child processes.

## Lines

The first line is the title. Every other line starts with a glyph and a space.

```
@1792047000.100 Deploy preview [6]
▶ @1792047000.200 id=812.1 pid=812 install dependencies
% @1792047003.950 id=812.1 31/48 left-pad
✔ @1792047014.400 id=812.1
▶ @1792047017.700 id=812.2 pid=812 unit tests
✘ @1792047039.100 id=812.2 2 failed
· @1792047039.200 failures are known flakes
```

| Glyph | Meaning |
|---|---|
| (first line) | Title, with the planned number of steps in brackets when known |
| `▶` | A step starts |
| `✔` | A step ends well. The text after it is a detail shown next to the step |
| `✘` | A step fails |
| `%` | Progress of a running step |
| `·` | A note, not a step |

A line with no glyph after the first is shown as a note.

## Metadata

Right after the glyph a line may carry metadata, which the helper always writes and hand-written lines can leave out.

- `@<seconds>` is the time, in seconds since the epoch, with or without a fraction. It must come first. With it the viewer shows durations, live elapsed time and an ETA.
- `id=<id>` ties a `✔`, `✘` or `%` line to the step that opened with the same id. Without an id they apply to the most recent step still running. Ids let parallel steps report without getting mixed up.
- `pid=<pid>` on a `▶` line names the process that owns the step. If that process is gone and the step never closed, the viewer shows it as interrupted instead of running forever.
- `ns=<inode>` on a `▶` line is the pid namespace of that process (Linux). A viewer in a different namespace does not check the pid.

Metadata tokens are only read after an `@<seconds>` token, so a hand-written `▶ id=3 rollout` keeps its text.

## Progress

```
% [@ts] [id=…] COUNT [label]
```

COUNT is one of the following.

| COUNT | Shown as |
|---|---|
| `37/120` | a bar, the count, and an ETA once the rate is known |
| `45%` | a bar and the percentage |
| `1.2G/4.0G`, `512Ki/2Mi` | a bar, with K, M, G, T (or Ki, Mi, Gi) taken into account |
| `12s/60s` | a bar for time against a limit, with no ETA |
| `17` | a bare count, no bar |
| `-` | nothing, only the label |

The label is free text, usually the current item.

## Writing it from other languages

Shell scripts source `unspin.sh`. Anything else can append lines. In Python, for example, the following reports into the step that is open in the shell that started the script.

```python
import os, time

def progress(n, total, label=""):
    path = os.environ.get("UNSPIN_FILE")
    if not path:
        return
    step = os.environ.get("UNSPIN_STEP")
    meta = f" id={step}" if step else ""
    with open(path, "a") as f:
        f.write(f"% @{time.time():.3f}{meta} {n}/{total} {label}\n")

for i, name in enumerate(files, 1):
    convert(name)
    progress(i, len(files), name)
```

Or call the CLI, which needs no code at all.

```
unspin progress 3 10 photo_003.jpg
unspin step "uploading"   ...   unspin ok
```

Keep progress writes to a few per second. The status line redraws once a second anyway.

## Compatibility

Version 1 of the helper wrote lines without metadata and put the duration into the closing line (`✔ fine 2.3s`). Those files still draw as before.
