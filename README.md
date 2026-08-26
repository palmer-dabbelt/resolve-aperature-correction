# resolve-aperture-correction

Fusion fuses for dealing with variable-aperture lenses in DaVinci Resolve.

A zoom lens sold as, say, 18-55mm f/3.5-5.6 loses light as you zoom in: push
from wide to long during a shot and the image darkens, in a ramp that has
nothing to do with the scene. The eventual goal here is a fuse that undoes that
ramp automatically.

Doing that *well* depends on a question nobody seems to have written down: does
Resolve hand the aperture through to Fusion as image metadata? If it does, the
correction can be driven directly from what the lens reported, which beats
inferring exposure changes from the pixels. If it doesn't, the correction has
to be image-analysis based instead.

So the first tool here is a probe that answers that question.

## Fuses

### Aperture Probe

A pass-through diagnostic. It doesn't touch the image; it prints whatever
metadata is riding along with it to the Fusion Console, and calls out anything
that looks lens-related.

The Fuse SDK documents a "list of known metadata" covering the old DPX/EXR
fields — filenames, timecode, colour primaries — and mentions lens data
nowhere. Whether anything more turns up depends entirely on the codec and on
which node decoded it, so the only reliable way to find out is to look at a
real clip.

**Controls**

| Control | What it does |
| --- | --- |
| Report | *When It Changes* (default), *Every Frame*, or *Never*. |
| List Every Field | Include metadata that isn't lens-related in the dump. On by default. |
| Report Again | Forces a fresh report, ignoring what was reported before. |

*When It Changes* exists so the tool can sit in a comp while you scrub without
burying the Console. It re-reports when the set of metadata keys changes, or
when a lens/exposure value changes — but deliberately not when only something
like `TimeCode` or `Filename` ticks over, which would otherwise fire on every
single frame.

**Reading the output**

Open the Console with **Workspace → Console** on the Fusion page. Reports look
like this:

```
-- Aperture Probe [ApertureProbe1] frame 1024 --
  14 field(s) total
  APERTURE:
    Aperture = 4.0
  lens / exposure:
    ISO = 800
    ShutterAngle = 180
  everything else:
    Filename = /clips/a.braw
    TimeCode = 01:00:00:04
```

The three outcomes that matter:

- **`APERTURE:` with a value** — the aperture is available per frame, and a
  metadata-driven correction is on the table.
- **`APERTURE: none found`, but other fields listed** — metadata reaches Fusion,
  just not the aperture. Worth checking whether a different source node exposes
  more.
- **`no metadata at all (Image.Metadata is nil)`** — nothing is coming through
  at this point in the comp.

Key matching is spelling-insensitive: keys are folded to lowercase alphanumerics
before comparison, so `F-Number`, `f_stop` and `FNumber` all register. Nested
metadata is flattened to dotted paths (`Lens.FocalLength`).

**Worth trying more than one setup.** Metadata availability varies by source, so
if the first answer is "nothing", it's worth probing a `MediaIn` on the Fusion
page of an edit-page clip, a `Loader` pointed straight at the file in a standalone
comp, and a camera-native format such as BRAW or R3D versus a transcode. A clip
that has been through a codec that can't carry metadata will have lost it long
before Fusion sees it.

## Installing

```sh
make install         # symlink into Resolve's Fuses directory
make install-copy    # copy instead of symlinking
make uninstall       # remove them again
```

Symlinking means edits to the repository take effect the next time Resolve
starts, without reinstalling.

Fuses are loaded at startup, so **restart Resolve** afterwards. The tool then
appears in the Fusion page's Effects Library under **Fuses → Metadata → Aperture
Probe**, or via Shift+Space as "Aperture Probe".

The default destination is:

- macOS: `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Fuses`
- Linux: `~/.local/share/DaVinciResolve/Fusion/Fuses`

Override it with `make install FUSEDIR=...` — useful for the system-wide
`/Library/Application Support/...` folder, or for testing somewhere harmless.
`make help` prints the path it would use.

`install` refuses to overwrite anything it didn't put there, and `uninstall`
only removes a symlink pointing back into this repository or a copy still
byte-identical to ours; anything else is left alone and reported. Pass `FORCE=1`
to install over a stranger anyway.

## Tests

The reporting logic runs against a stubbed-out Fusion host, so it can be tested
without launching Resolve:

```sh
make test     # run the suite
make check    # syntax-check the Lua without running it
make          # both
```

`test/harness.lua` implements just enough of the Fuse API — `AddInput`,
`AddOutput`, `Input:GetValue`, `Output:Set`, `Request:GetTime` and a captured
`print` — to load a `.fuse` into a sandbox and drive `Process()` against
synthetic metadata.

Any Lua 5.1-compatible interpreter works; the default is `luajit`, overridable
with `make test LUA=lua5.1`. `make install` runs `check` first so a fuse that
won't parse never reaches Resolve, but tolerates having no interpreter at all
rather than making Lua a prerequisite for installing.

## Reference

These fuses are written against `Fusion18_Fuse_SDK.pdf`, Blackmagic's Fuse SDK
documentation. The metadata API is covered in its "MetaData" chapter. The PDF
sits untracked in the working copy rather than being committed here.
