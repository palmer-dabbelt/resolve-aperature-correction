# resolve-aperture-correction

Fusion fuses for dealing with variable-aperture lenses in DaVinci Resolve.

A zoom lens sold as, say, 10-22mm f/3.5-4.5 loses light as you zoom in: push
from wide to long during a shot and the image darkens, in a ramp that has
nothing to do with the scene. **Aperture Normalize** undoes that ramp.

Doing it well depended on a question nobody seems to have written down: does
Resolve hand the aperture through to Fusion as image metadata? It turns out
that for BRAW it does, in quantity —

```
aperture = f3.5
focal_length = 10mm
lens_type = Canon EF-S 10-22mm f/3.5-4.5 USM
```

— so the correction is driven by what the lens actually reported, rather than
inferred from the pixels. **Aperture Probe** is the diagnostic that established
that, and is still the tool for finding out what a given camera tags.

## Fuses

### Aperture Normalize

The correction itself. It reads the aperture the camera recorded for each
frame, and applies the gain that would have made it look like it was shot at a
target aperture — f/4 by default, the middle of the 10-22mm's range.

Illuminance at the sensor goes as 1/N² for an f-number N, so matching a frame
shot at N to the target is a gain of `(N / target)²`. At f/3.5 against a f/4
target that's ×0.766, a third of a stop darker; at f/4.5 it's ×1.266 brighter.
The gain is applied to R, G and B but not alpha, which is coverage rather than
light.

**It is meant to be safe to leave enabled on every clip.** Anything it does not
positively understand is passed through untouched and uncopied, with the reason
printed once to the Console:

- the image carries no metadata, or no `lens_type`, or no `aperture`
- the lens isn't in the database below
- the aperture can't be parsed, or is one the lens couldn't have produced
- the image isn't in linear light (a gain is only meaningful there)
- the correction works out larger than 3 stops, which means the metadata is
  lying rather than that the shot needs it
- the correction is smaller than a thousandth of a stop — the frame is already
  at the target aperture, and that is invisible

**Force On Unknown Lenses** overrides the second of those: an unlisted lens, or
metadata with no `lens_type` at all, gets corrected from whatever aperture it
reports. It deliberately does *not* override the rest. Those are cases where
the maths would be wrong rather than merely unvouched-for, and forcing is about
lenses you know are fine, not about overriding arithmetic.

When it *does* correct, it stamps
`aperture_normalize.{gain,stops,from,target,lens,forced,focal,distance}` into
the output metadata, so a tool placed downstream shows the correction next to
the values it came from.

| Control | What it does |
| --- | --- |
| Target Aperture | The f-number to normalise to. Default 4. |
| Force On Unknown Lenses | Correct lenses that aren't in the database. Off by default. |
| Processing | *GPU (falls back to CPU)* by default, or *CPU* to compare the two. |
| Console Logging | Master switch for Console output. On by default. |
| Report | *When It Changes* (default) or *Every Frame*. |
| Report Folder | Where **Generate Report** writes. |
| Generate Report | Dumps the current frame's full state to a file. |

#### Generate Report

Pick a **Report Folder**, then press **Generate Report**. The next frame that
renders writes `aperture-normalize-<clip>-<frame>.txt` there, containing the
settings in force, what the tool decided and why, and a complete dump of the
frame's metadata with nested fields flattened to dotted paths.

It fires once per press rather than continuously, and it's most useful on a
frame that *isn't* being corrected — the report says exactly which check
rejected it. This is what replaced needing Aperture Probe in the comp.

#### Zoom position

The camera reports the aperture quantised to marked stops — it jumps f/3.5,
f/3.6, f/4 — but the light a variable-aperture zoom actually passes ramps
smoothly with zoom position. So the focal length is the finer-grained signal,
and the report carries it, along with the focus distance, which also bears on
how much light reaches the sensor:

```
-- Aperture Normalize [ApertureNormalize1] frame 5886 --
  lens       : Canon EF-S 10-22mm f/3.5-4.5 USM
  aperture   : f3.5 -> target f4
  correction : -0.385 stops (gain 0.7656)
  zoom       : 10mm  (focus 2240mm to 6480mm)
```

The zoom counts as a change, so a ramp reports at every distinct focal length
rather than only where the reported f-number steps — which is what makes the
output usable for deriving a correction curve. It is reported on frames that
are *passed through* too, since those are part of the same curve. That is a lot
more lines than before, hence **Console Logging** as a master switch.

The lens database's `stops` table is still keyed by f-number. Keying a
correction on focal length instead is the obvious next step, once there is
measured data to key it on.

#### Performance

The tool runs on every frame of playback, and a 6K frame is a few hundred
megabytes.

Resolve composites on the GPU, so a fuse that touches pixels from Lua drags the
whole frame down to host memory and back — which costs far more than the
multiply itself. The correction is therefore a DCTL compute kernel, running
where the image already is. If no GPU path is available the tool falls back to
`CopyOf` + `Gain` on the CPU, says so in the Console once, and does not retry:
the kernel either compiles on a given machine or it does not, and retrying per
frame would cost a failed compile on top of the CPU work.

**Processing** forces the CPU path, which is there to compare the two.

Beyond that:

- Alpha is never touched. It is coverage, not light.
- A frame needing no correction is passed through by reference, so a clip shot
  at the target aperture costs nothing at all.
- The decision is recomputed only when something it depends on changes: the
  lens, the aperture, the zoom, the encoding, or a control. On a static shot
  that is once per clip rather than once per frame.

#### The lens database

Near the top of `Fuses/ApertureNormalize.fuse`:

```lua
local LENSES = {
	["Canon EF-S 10-22mm f/3.5-4.5 USM"] = {
		aperture_range = { 3.5, 29 },
		stops = nil,
	},
}
```

Keyed by the `lens_type` metadata string. Lookup collapses whitespace and
ignores case but is otherwise exact, so an unlisted lens is passed through —
that's what makes the filter safe to apply globally.

`aperture_range` is the pair of marked f-numbers the lens can actually reach.
An aperture outside it is treated as bad metadata rather than as a very large
correction.

`stops` is optional and unset so far. The inverse-square law assumes the marked
f-number equals actual transmission, which real glass only approximates; this
is where measured deviation goes, as `{[f_number] = correction_in_stops}`,
interpolated between the points given and added on top of the computed
correction. Use the Aperture Probe's CSV dump to measure it. It's better to
leave it nil than to guess.

### Aperture Probe

Not installed by default — `make install-all` if you want it. A pass-through
diagnostic. It doesn't touch the image; it prints whatever
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
| Log Directory | Empty by default. Set it to also dump to disk. |
| Start Log Over | Truncates the dumps and starts the capture again. |

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

**Logging to disk.** Reading the Console gets old once you want the whole clip
at once. Set **Log Directory** and the tool also writes, per clip:

```
<dir>/<clip>.csv    one row per field per frame: frame,field,value
<dir>/<clip>.log    the same text that goes to the Console
```

Logging is off until you set that path — a fuse that silently started writing
files would be rude. The dumps are named after the clip, so probing a second
one doesn't append to the first one's files.

The Console report and the dumps are gated differently on purpose. The Console
is a live diagnostic, so it obeys the Report control. The files are a data
capture, so they record every frame that renders, exactly once each, whatever
Report is set to — scrub or render the clip and the CSV fills in behind you.
Re-rendering a frame doesn't duplicate its rows; **Start Log Over** truncates
and begins again.

The CSV is long-format (`frame,field,value`) rather than one column per field.
That keeps every row self-contained, which matters because Fusion renders
frames on several threads and out of order. Rows may therefore not be in frame
order — sort them if you care.

A sandboxed Resolve may refuse to write outside its container. If that happens
the tool says so in the Console once, with the path and the underlying error,
rather than failing silently.

**Worth trying more than one setup.** Metadata availability varies by source, so
if the first answer is "nothing", it's worth probing a `MediaIn` on the Fusion
page of an edit-page clip, a `Loader` pointed straight at the file in a standalone
comp, and a camera-native format such as BRAW or R3D versus a transcode. A clip
that has been through a codec that can't carry metadata will have lost it long
before Fusion sees it.

## Installing

```sh
make install         # install Aperture Normalize
make install-all     # ...and Aperture Probe too
make uninstall       # remove whatever this repository installed
```

`make install` deliberately installs only **Aperture Normalize**. The probe is
a diagnostic rather than something to leave in a comp, and the normaliser can
write its own report now. `make uninstall` still sweeps both, so it cleans up
after an earlier `install-all`.

Fuses are loaded at startup, so **restart Resolve** afterwards. The tool then
appears in the Fusion page's Effects Library under **Fuses → Metadata → Aperture
Probe**, or via Shift+Space as "Aperture Probe".

### Where it installs, and why it might not be where you expect

The Mac App Store build of Resolve is sandboxed, so the Fusion profile it
actually reads is redirected into the app's container:

```
~/Library/Containers/com.blackmagic-design.DaVinciResolveLite/Data/Library/Application Support/Fusion/Fuses
```

The non-sandboxed build uses the obvious path instead:

- macOS: `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Fuses`
- Linux: `~/.local/share/DaVinciResolve/Fusion/Fuses`

Installing to the wrong one of those looks like it succeeded and silently does
nothing, which is an annoying way to lose half an hour. `make install` detects
a container and prefers it; `make help` prints the path it would use, so check
that first if a fuse isn't showing up.

Override with `make install FUSEDIR=...` for anywhere else — the system-wide
`/Library/Application Support/...` folder, or a scratch directory for testing.

Installs are copies when the destination is inside a sandbox container, because
a sandboxed Resolve can't read through a symlink pointing out of it, and
symlinks elsewhere so that edits take effect on the next Resolve restart. Force
either with `make install-copy` or `make install-symlink`. **After editing a
fuse that was installed as a copy, re-run `make install`.**

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
