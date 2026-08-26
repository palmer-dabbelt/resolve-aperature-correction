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
target aperture — by default the widest the lens opens to, f/3.5 for the
10-22mm.

Illuminance at the sensor goes as 1/N² for an f-number N, so matching a frame
shot at N to the target is a gain of `(N / target)²`. At f/4.5 against a f/3.5
target that's ×1.653, three quarters of a stop brighter. The gain is applied to
R, G and B but not alpha, which is coverage rather than light.

**It is meant to be safe to leave enabled on every clip.** Anything it does not
positively understand is passed through untouched and uncopied, with the reason
printed once to the Console:

- the image carries no metadata, or no `lens_type`, or no `aperture`
- the lens isn't in the database below
- the aperture can't be parsed, or is one the lens couldn't have produced
- the image isn't in linear light (a gain is only meaningful there)
- the correction works out larger than 3 stops, which means the metadata is
  lying rather than that the shot needs it

**Force On Unknown Lenses** overrides the second of those: an unlisted lens, or
metadata with no `lens_type` at all, gets corrected from whatever aperture it
reports. It deliberately does *not* override the rest. Those are cases where
the maths would be wrong rather than merely unvouched-for, and forcing is about
lenses you know are fine, not about overriding arithmetic.

#### What it normalises to

Whatever **Target Aperture** says — and the tool fills that in for you. The
first time a lens from the database turns up, the widest aperture that lens has
is written into the slider: f/3.5 for the 10-22mm, taken from the first half of
its `aperture_range`.

That is the one target every frame of a zoom can actually be brought to,
because the ramp only ever runs from there towards darker, so every correction
brightens and none of them throw light away. It also means a clip is matched to
its own wide end rather than to an f-number picked in advance.

```
  aperture   : f4.5 -> target f3.5
  correction : +0.725 stops (gain 1.6531)
  zoom       : 22mm
```

Type something else into the slider and it stays there. The tool only ever
overwrites two things: the factory default, and a value it wrote itself. So a
comp where the target was deliberately set to f/5.6 keeps f/5.6 however many
lenses go past, while a timeline that changes lens re-fills rather than keeping
the first lens's answer. A lens that isn't in the database has no widest to
fill in from, so the slider keeps whatever it had — including under **Force On
Unknown Lenses**, which supplies permission rather than data.

The consequence to know about is that normalising to the widest only ever adds
gain, so a long-end frame exposed to the top of the range will clip where it
previously wouldn't have. If that matters, set **Target Aperture** to the
narrow end instead — everything then darkens rather than brightens. That is
also how to take several different lenses to one common f-number.

When it *does* correct, it stamps
`aperture_normalize.{gain,stops,from,target,lens,forced,focal,distance}` into
the output metadata — plus `reported`, on the frames where the camera's
f-number was [overruled](#the-lens-lies-about-being-wide-open) — so a tool
placed downstream shows the correction next to the values it came from.

| Control | What it does |
| --- | --- |
| Target Aperture | The f-number to normalise to. Filled in with the lens's widest; ships at 4. |
| Force On Unknown Lenses | Correct lenses that aren't in the database. Off by default. |
| Processing | *GPU (falls back to CPU)* by default; either CPU path, to compare them; or *Off: publish gain only*, which touches no pixels and leaves the multiply to a downstream tool. |
| Console Logging | *None*, *Errors* (default), *Corrections*, or *All Metadata*. |
| Report | *When It Changes* (default) or *Every Frame*. |

#### Console Logging

Four settings, from silent to everything:

| Mode | What reaches the Console |
| --- | --- |
| None | Nothing at all. |
| Errors | Only the frames it *declines* to correct, one line per distinct reason. The default. |
| Corrections | Every correction, as the aperture and the zoom change. |
| All Metadata | The above, plus every field the image carries. |

**Errors** is the default because it is the one that's useful to leave on. A
clip the tool understands produces no output whatsoever; a clip it won't touch
says so once, with the reason. It's deduplicated by reason rather than by
frame — an unlisted lens is one fact about the clip, so saying it again at
every focal length would make the quiet mode the noisiest one.

**All Metadata** is the mode for finding out what the camera actually tags, and
for a specific reason. The zoom arrives in whole millimetres, so the correction
is a staircase: every frame the camera calls 15mm gets an identical gain, and
the real ramp inside that step goes uncorrected. What would fix it is a
finer-grained number — a raw encoder count, a subdivided focal length — if the
camera writes one. This is how to go looking.

Which is why the fields that *moved* are marked rather than merely printed:

```
  metadata   : 7 field(s), 1 changed since frame 100
     Filename         = /clips/A067.braw
     GammaSpace.Gamma = 1
     aperture         = f3.5
     distance         = 2240mm to 6480mm
     focal_length     = 15mm
     lens_type        = Canon EF-S 10-22mm f/3.5-4.5 USM
   * zoom_encoder     = 4837   (was 4821)
```

A field ticking while `focal_length` sits still is exactly what's being looked
for, and finding it by eye across two screenfuls of identical values is the
sort of thing people give up on halfway. `*` changed, `+` appeared, `-` went
away, and nested fields are flattened to dotted paths.

In this mode "has anything changed" widens to the whole of the metadata rather
than just the parts the correction is computed from. It has to: a field that
moves while the zoom and the aperture hold still would otherwise never trigger
a report, and so would never be printed — which is precisely the field being
hunted.

Frames render on several threads and out of order, so the frame compared
against is named in the header rather than assumed to be this one minus one.

#### Zoom position

The camera reports the aperture quantised to marked stops — it jumps f/3.5,
f/3.6, f/4 — but the light a variable-aperture zoom actually passes ramps
smoothly with zoom position. So the focal length is the finer-grained signal,
and the report carries it, along with the focus distance, which also bears on
how much light reaches the sensor:

```
-- Aperture Normalize [ApertureNormalize1] frame 5886 --
  lens       : Canon EF-S 10-22mm f/3.5-4.5 USM
  aperture   : f4 -> target f3.5
  correction : +0.385 stops (gain 1.3061)
  zoom       : 10mm  (focus 2240mm to 6480mm)
```

The zoom counts as a change, so a ramp reports at every distinct focal length
rather than only where the reported f-number steps — which is what makes the
output usable for deriving a correction curve. It is reported on frames that
are *passed through* too, since those are part of the same curve. That is a lot
more lines than before, which is what *Errors* being the default setting of
**Console Logging** is for.

#### The lens lies about being wide open

That quantisation isn't just coarse, it's biased. Watch the Canon 10-22 zoom in
from the wide end and it reports f/3.5 at 10mm, f/3.5 at 12mm — and the 12mm
frame is visibly darker. The aperture has been ramping the whole way; the
camera only tells you about it when the ramp crosses the next marked stop, so
wide open the reported f-number is always the same or too wide, never too
narrow. Correcting from it under-corrects exactly where the correction is
needed.

The fix is a second per-lens table, `max_aperture`, keyed by focal length:
how wide the lens will actually open at each zoom position. Where it says the
reported aperture is wider than the lens can physically reach, the table wins.

```
-- Aperture Normalize [ApertureNormalize1] frame 5931 --
  lens       : Canon EF-S 10-22mm f/3.5-4.5 USM
  aperture   : f3.7 -> target f3.5
  wide open  : f3.5 reported, but this lens only opens to f3.7 at 12mm
  correction : +0.160 stops (gain 1.1176)
  zoom       : 12mm  (focus 2240mm to 6480mm)
```

It's a floor on the f-number rather than a replacement for it, which is what
makes it safe: it can only ever fire on a reported value that was impossible to
begin with. Stopped down to f/8 at 12mm, f/8 is perfectly reachable, so the
metadata is believed and nothing changes. It also does nothing without a
`focal_length`, and nothing for a lens that has no table — including a forced
one, since forcing supplies permission, not data.

When it does fire, both f-numbers are recorded: the report gets the `wide open`
line above, and the metadata stamp gets `reported` alongside `from`. A stamp
with no `reported` field means the correction came from exactly what the camera
said.

#### Performance

The tool runs on every frame of playback, and a 6K frame is a few hundred
megabytes.

Resolve composites on the GPU, so a fuse that touches pixels from Lua drags the
whole frame down to host memory and back — which costs far more than the
multiply itself. The correction is therefore a DCTL compute kernel, running
where the image already is.

If the GPU path is unavailable the tool falls back to the CPU, says so in the
Console once — naming the step that failed, which distinguishes "this build has
no GPU fuse support" from "the kernel would not compile" — and does not retry.
The kernel either compiles on a given machine or it does not, and retrying per
frame would cost a failed compile on top of the CPU work.

**Processing** selects between four paths, so they can be compared on real
footage rather than argued about:

| Mode | What it does |
| --- | --- |
| GPU | The DCTL kernel, falling back to *copy + gain* if it can't run. |
| CPU: copy + gain | `CopyOf` then `Gain` in place. The documented pattern, two passes over the frame. |
| CPU: channel op | One multiplying `ChannelOpOf`. One pass in principle, but through general channel-boolean machinery that may cost more than it saves. |
| Off: publish gain only | Touches no pixels at all. The image is passed through by reference and the correction leaves only by the **Gain** output. |

#### Letting a native tool do the multiply

Every mode but the last one moves the whole frame through Lua. Even where the
arithmetic is a single native call, a 6K RGBA float frame is a few hundred
megabytes to allocate and copy, per frame — and that cost does not depend on
how simple the correction is.

That copy turned out to be effectively the whole cost. On 6K BRAW the three
pixel-touching modes all played at roughly 7–17fps and differed little from
each other, while *publish gain only* plays at a full 23.976. It is worth
knowing that the modes were close together: it means there was nothing to win
by making the multiply itself cheaper, which is why the GPU kernel was not the
answer either.

So the tool has a second output, **Gain**, carrying the correction as a plain
number. Set Processing to *Off: publish gain only*, put a BrightnessContrast
after it, and connect Gain to the BrightnessContrast's Gain input. The pixels
are then handled by a native tool that has its own GPU path, and this fuse only
reads metadata and does some arithmetic.

Two things to know about that arrangement:

- The **blue** input on BrightnessContrast is its Effect Mask — an image input
  that limits *where* the correction applies. It is not a control input, and
  connecting Gain to it will not work.
- Nothing is stamped into the metadata in this mode. Writing a stamp needs the
  image copy the mode exists to avoid.

Gain is published on every frame, including passed-through ones, where it is
1.0. An output that went absent would leave whatever consumed it holding a
stale gain from some earlier frame.

Beyond that:

- Alpha is never touched. It is coverage, not light.
- A frame whose correction works out to nothing is *not* a special case. It
  used to be passed through by reference, to save the copy, but the **Gain**
  output has to publish a number for it either way — and on a zoom ramp the one
  frame that lands exactly on the target sits between two that don't, so
  reporting it as a pass-through read as though the tool had stopped working
  halfway through the shot. It now reports and publishes like any other frame.
- The decision is recomputed only when something it depends on changes: the
  lens, the aperture, the zoom, the encoding, or a control. On a static shot
  that is once per clip rather than once per frame.

#### The lens database

Near the top of `Fuses/ApertureNormalize.fuse`:

```lua
local LENSES = {
	["Canon EF-S 10-22mm f/3.5-4.5 USM"] = {
		aperture_range = { 3.5, 29 },
		max_aperture = {
			[10] = 3.5, [11] = 3.6, [12] = 3.7, [13] = 3.8,
			[15] = 4.0, [17] = 4.2, [20] = 4.5, [22] = 4.5,
		},
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

`max_aperture` is the widest aperture available at each zoom position, keyed by
focal length in millimetres, linear between the entries and flat outside them —
the table behind [the section above](#the-lens-lies-about-being-wide-open).
The 10-22's entries at 10, 11, 12, 13, 15 and 17mm are where the reported
f-number was seen to change on one copy of the lens, which works out at a tenth
of a stop-marking per millimetre. Past 17mm is a guess: that same tenth per
millimetre continued until it reaches the f/4.5 the lens is sold as, then flat
to the long end. That's the part to check first if a long-end shot looks
over-corrected.

Unlike `stops` below, guessing here is defensible, because an inferred ramp
between two observed points is much closer to the truth than the step function
the camera reports — and because the floor rule means a wrong entry can only
affect frames shot at or near wide open.

`stops` is optional and unset so far. The inverse-square law assumes the marked
f-number equals actual transmission, which real glass only approximates; this
is where measured deviation goes, as `{[f_number] = correction_in_stops}`,
interpolated between the points given and added on top of the computed
correction. Use the Aperture Probe's CSV dump to measure it. It's better to
leave it nil than to guess: it's a fudge factor applied everywhere, with
nothing physical to bound it.

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
a diagnostic rather than something to leave in a comp, and the normaliser's
*All Metadata* logging covers most of what it was needed for in the first
place. Reach for the probe when you want a whole clip captured to CSV rather
than a Console you can scroll. `make uninstall` still sweeps both, so it cleans
up after an earlier `install-all`.

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
