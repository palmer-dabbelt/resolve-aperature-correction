--[[--
Tests for ApertureNormalize.

Run with:  lua test/test_aperturenormalize.lua   (from the repository root)
--]]--

package.path = "test/?.lua;" .. package.path
local harness = require("harness")
local tap = require("tap")

local FUSE = "Fuses/ApertureNormalize.fuse"

local check, contains, near = tap.check, tap.contains, tap.near

local LENS = "Canon EF-S 10-22mm f/3.5-4.5 USM"

-- Most of what follows is about the arithmetic, and reads much better against
-- a target that stays put, so these pin it to f/4 -- what the slider ships set
-- to -- rather than letting it follow the lens. The shipped default is that it
-- does follow the lens; newDefaultTool() is the untouched tool, and the
-- "normalising to the lens's widest" section below is where that is tested.
local function newTool()
	local tool = harness.load(FUSE)
	tool:set("AutoTarget", 0)
	return tool
end

local function newDefaultTool()
	return harness.load(FUSE)
end

-- BRAW-ish metadata, with any field overridable per test. Pass "<nil>" to drop
-- a field entirely.
local function meta(over)
	local m = {
		Filename = "/clips/A067_08211340_C007.braw",
		lens_type = LENS,
		aperture = "f3.5",
		focal_length = "10mm",
		distance = "2240mm to 6480mm",
		GammaSpace = { Gamma = 1 },
	}
	for k, v in pairs(over or {}) do
		if v == "<nil>" then v = nil end
		m[k] = v
	end
	return m
end

-- The gain a correcting frame applied, whichever path applied it, or nil if
-- the frame passed through.
local function appliedGain(out)
	if out.gpu then return out.gpu.gain end
	if out.gains[1] then return out.gains[1].r end
	if out.channelOp then return out.channelOp.options.R end
	return nil
end

local function checkPassThrough(label, metadata, tool)
	tool = tool or newTool()
	local report, out, img = tool:process(metadata, 1)
	check(label .. ": output is the input", out == img, report)
	check(label .. ": nothing was applied", appliedGain(out) == nil)
	check(label .. ": says so in the Console", contains(report, "passing through"), report)
	return report
end

tap.section("registration")
do
	local tool = newTool()
	local reg = tool.registration
	check("registers a CT_Tool", reg ~= nil and reg.classtype == "CT_Tool")
	check("class name is ApertureNormalize", reg and reg.name == "ApertureNormalize", reg and reg.name)
	check("has a display name", reg and reg.attrs.REGS_Name == "Aperture Normalize")
end

tap.section("the correction itself")
do
	-- f/3.5 normalised to f/4 is (3.5/4)^2 = 0.765625, i.e. it darkens.
	local tool = newTool()
	local report, out, img = tool:process(meta(), 1)

	check("output is a new image", out ~= img)
	check("gain is (3.5/4)^2", near(appliedGain(out), 0.765625), appliedGain(out))
	check("reports the stops", contains(report, "-0.385 stops"), report)
	check("names the lens", contains(report, LENS), report)
end

do
	-- f/4.5 is dimmer than f/4, so normalising brightens.
	local tool = newTool()
	local _, out = tool:process(meta({ aperture = "f4.5" }), 1)
	check("f/4.5 brightens", near(appliedGain(out), (4.5 / 4) ^ 2), appliedGain(out))
end

tap.section("target aperture")
do
	local tool = newTool()
	tool:set("TargetAperture", 5.6)
	local _, out = tool:process(meta(), 1)
	check("honours a different target", near(appliedGain(out), (3.5 / 5.6) ^ 2), appliedGain(out))
end

do
	local tool = newTool()
	tool:set("TargetAperture", 0)
	checkPassThrough("target of zero", meta(), tool)
end

tap.section("aperture parsing")
do
	for _, written in ipairs({ "f3.5", "F3.5", "F/3.5", "3.5", "f 3.5" }) do
		local tool = newTool()
		local _, out = tool:process(meta({ aperture = written }), 1)
		check('reads "' .. written .. '"', near(appliedGain(out), 0.765625), appliedGain(out))
	end
end

tap.section("anything not understood is passed through")
do
	checkPassThrough("no metadata", nil)
	checkPassThrough("no lens_type", meta({ lens_type = "<nil>" }))
	checkPassThrough("no aperture", meta({ aperture = "<nil>" }))

	local r = checkPassThrough("unknown lens", meta({ lens_type = "Sigma 18-35mm f/1.8 DC HSM" }))
	check("names the unknown lens", contains(r, "Sigma 18-35mm f/1.8 DC HSM"), r)

	r = checkPassThrough("unparseable aperture", meta({ aperture = "wide open" }))
	check("quotes what it could not read", contains(r, "wide open"), r)

	-- f/1.8 is wider than this lens opens, so the metadata must be wrong.
	r = checkPassThrough("aperture the lens cannot reach", meta({ aperture = "f1.8" }))
	check("explains the range", contains(r, "outside"), r)

	r = checkPassThrough("non-linear image", meta({ GammaSpace = { Gamma = 2.2 } }))
	check("mentions the gamma", contains(r, "2.2"), r)
end

do
	local tool = newTool()
	tool:set("TargetAperture", 0.5)
	local report, out, img = tool:process(meta({ aperture = "f29" }), 1)
	check("absurd correction is refused", out == img and appliedGain(out) == nil, report)
	check("says why", contains(report, "too large"), report)
end

tap.section("a correction of nothing is still a correction")
do
	-- This used to be a pass-through, to save a full-frame copy. It no longer
	-- is: the Gain output has to publish a number for this frame either way,
	-- and on a zoom ramp the frame that happens to land on the target sits
	-- between two that don't, so reporting it as a pass-through made the tool
	-- look like it had stopped working halfway through the shot.
	local tool = newTool()
	local report, out, img = tool:process(meta({ aperture = "f4" }), 1)

	check("a frame already at the target is not passed through", out ~= img)
	check("its gain is unity", near(appliedGain(out), 1.0), appliedGain(out))
	check("it is published as unity too", near(tool.out.Gain.Value, 1.0), tool.out.Gain.Value)
	check("and reported like any other frame", contains(report, "+0.000 stops"), report)
	check("without claiming to have passed anything through",
		not contains(report, "passing through"), report)
end

tap.section("Force On Unknown Lenses")
do
	local tool = newTool()
	tool:set("Force", 1)
	local report, out = tool:process(meta({ lens_type = "Sigma 18-35mm f/1.8 DC HSM" }), 1)
	check("corrects an unlisted lens", near(appliedGain(out), 0.765625), appliedGain(out))
	check("says the correction was forced", contains(report, "forced"), report)
	check("still names the lens", contains(report, "Sigma 18-35mm f/1.8 DC HSM"), report)
end

do
	local tool = newTool()
	tool:set("Force", 1)
	local report, out = tool:process(meta({ lens_type = "<nil>" }), 1)
	check("covers metadata with no lens at all", near(appliedGain(out), 0.765625), appliedGain(out))
	check("calls it unidentified", contains(report, "unidentified lens"), report)
end

do
	-- Forcing is about unknown lenses, not about overriding the maths.
	local tool = newTool()
	tool:set("Force", 1)
	checkPassThrough("forcing does not override missing aperture",
		meta({ lens_type = "<nil>", aperture = "<nil>" }), tool)

	local tool2 = newTool()
	tool2:set("Force", 1)
	checkPassThrough("forcing does not override non-linear light",
		meta({ GammaSpace = { Gamma = 2.2 } }), tool2)
end

do
	-- A listed lens keeps its range check even when forcing.
	local tool = newTool()
	tool:set("Force", 1)
	checkPassThrough("forcing keeps a known lens's range check", meta({ aperture = "f1.8" }), tool)
end

tap.section("lens matching")
do
	for _, spelling in ipairs({
		LENS,
		LENS:lower(),
		LENS:upper(),
		"Canon  EF-S   10-22mm  f/3.5-4.5  USM",
		"  " .. LENS .. "  ",
	}) do
		local tool = newTool()
		local _, out = tool:process(meta({ lens_type = spelling }), 1)
		check("matches " .. string.format("%q", spelling), appliedGain(out) ~= nil)
	end
end

tap.section("the correction runs on the GPU")
do
	local tool = newTool()
	local _, out, img = tool:process(meta(), 1)

	check("used the GPU", out.gpu ~= nil)
	check("ran the aperture kernel", out.gpu and out.gpu.kernel == "ApertureGainKernel",
		out.gpu and out.gpu.kernel)
	check("handed the kernel the gain", near(out.gpu.gain, 0.765625), out.gpu.gain)
	check("read the source image", out.gpu.inputs.src == img)
	check("sampled point-wise in pixel coordinates",
		out.gpu.sampler.filter == "point" and out.gpu.sampler.norm == false,
		out.gpu.sampler and out.gpu.sampler.filter)
	check("did not also do it on the CPU", #out.gains == 0)
end

do
	-- Processing = CPU: copy + gain.
	local tool = newTool()
	tool:set("Processing", 1)
	local _, out = tool:process(meta(), 1)

	check("copy+gain leaves the GPU alone", out.gpu == nil)
	check("copy+gain applies the same gain", near(appliedGain(out), 0.765625), appliedGain(out))
	check("copy+gain leaves alpha at unity", out.gains[1].a == 1.0, out.gains[1].a)
end

do
	-- Processing = CPU: channel op, the other CPU path, kept for comparison.
	local tool = newTool()
	tool:set("Processing", 2)
	local _, out = tool:process(meta(), 1)

	check("channel op leaves the GPU alone", out.gpu == nil)
	check("channel op multiplies", out.channelOp and out.channelOp.operation == "Multiply",
		out.channelOp and out.channelOp.operation)
	check("channel op applies the same gain",
		near(out.channelOp.options.R, 0.765625), out.channelOp.options.R)
	check("channel op leaves alpha out entirely", out.channelOp.options.A == nil)
end

do
	-- A host with no GPU falls back rather than failing.
	local tool = newTool()
	tool.gpuAvailable = false
	local report, out = tool:process(meta(), 1)

	check("falls back to the CPU", out.gpu == nil and near(appliedGain(out), 0.765625), appliedGain(out))
	check("says so once", contains(tool.printed[#tool.printed], "GPU path unavailable"),
		tool.printed[#tool.printed])
	check("and says which step failed",
		contains(tool.printed[#tool.printed], "DVIPComputeNode returned nothing"),
		tool.printed[#tool.printed])

	local before = #tool.printed
	tool.lastNode = nil
	tool.gpuAvailable = true          -- even if a GPU turns up, don't go back
	tool:process(meta({ aperture = "f4.5" }), 2)

	local complaints = 0
	for i = before + 1, #tool.printed do
		if contains(tool.printed[i], "GPU path unavailable") then complaints = complaints + 1 end
	end
	check("and does not keep saying it", complaints == 0)
	check("and does not keep retrying it", tool.lastNode == nil)
end

do
	-- A kernel that will not run is also just a fallback.
	local tool = newTool()
	tool.gpuRuns = false
	local _, out = tool:process(meta(), 1)
	check("a failed kernel falls back too",
		out.gpu == nil and near(appliedGain(out), 0.765625), appliedGain(out))
end

tap.section("the gain is published as a number too")
do
	local tool = newTool()

	local attrs = tool.outputAttrs.Gain
	check("there is a Gain output", attrs ~= nil)
	check("carrying a number", attrs and attrs.LINKID_DataType == "Number",
		attrs and attrs.LINKID_DataType)
	check("as a second output, not in place of the image",
		attrs and attrs.LINK_Main == 2, attrs and attrs.LINK_Main)

	tool:process(meta(), 1)
	check("published on a correcting frame",
		near(tool.out.Gain.Value, 0.765625), tool.out.Gain.Value)
end

do
	-- A skipped frame still has to say something, or whatever is reading the
	-- output keeps applying the last gain it saw to footage it does not suit.
	local tool = newTool()
	tool:process(meta({ lens_type = "Some Lens Nobody Has Measured" }), 1)
	check("a passed-through frame publishes unity",
		tool.out.Gain and tool.out.Gain.Value == 1.0, tool.out.Gain and tool.out.Gain.Value)
end

tap.section("Off: publish gain only")
do
	-- The point of this mode: hand the pixels to a native tool and touch none
	-- of them here.
	local tool = newTool()
	tool:set("Processing", 3)
	local _, out, img = tool:process(meta(), 1)

	check("the image is passed through untouched", out == img)
	check("no CPU copy", #out.gains == 0)
	check("no channel op", out.channelOp == nil)
	check("no GPU kernel", out.gpu == nil)
	check("but the gain is still published",
		near(tool.out.Gain.Value, 0.765625), tool.out.Gain.Value)
	check("and no metadata stamp, which would need the copy",
		out.Metadata.aperture_normalize == nil)
end

do
	-- Reporting is independent of who applies the gain.
	local tool = newTool()
	tool:set("Processing", 3)
	local report = tool:process(meta(), 1)
	check("still reports the correction", contains(report, "0.7656"), report)
end

tap.section("metadata stamping")
do
	local tool = newTool()
	local input = meta()
	local _, out, img = tool:process(input, 1)

	local stamped = out.Metadata.aperture_normalize
	check("stamps the output", type(stamped) == "table")
	check("records the gain", stamped and near(tonumber(stamped.gain), 0.765625), stamped and stamped.gain)
	check("records the source aperture", stamped and stamped.from == "f3.5", stamped and stamped.from)
	check("records the target", stamped and stamped.target == "f4", stamped and stamped.target)
	check("records the lens", stamped and stamped.lens == LENS)
	check("records that it was not forced", stamped and stamped.forced == "0", stamped and stamped.forced)
	check("records the zoom position", stamped and stamped.focal == "10mm", stamped and stamped.focal)
	check("records the focus distance",
		stamped and stamped.distance == "2240mm to 6480mm", stamped and stamped.distance)
	check("keeps the original fields", out.Metadata.focal_length == "10mm")

	check("does not mutate the input's metadata", input.aperture_normalize == nil)
	check("input image metadata untouched", img.Metadata.aperture_normalize == nil)
end

tap.section("decisions are cached across frames")
do
	local tool = newTool()
	local first = tool:process(meta(), 1)
	local _, out = tool:process(meta({ aperture = "f3.5" }), 2)
	check("same inputs still correct on later frames", near(appliedGain(out), 0.765625), appliedGain(out))

	-- Changing an input the decision depends on must invalidate the cache.
	local _, out2 = tool:process(meta({ aperture = "f4.5" }), 3)
	check("a new aperture is noticed", near(appliedGain(out2), (4.5 / 4) ^ 2), appliedGain(out2))

	tool:set("TargetAperture", 5.6)
	local _, out3 = tool:process(meta({ aperture = "f4.5" }), 4)
	check("a new target is noticed", near(appliedGain(out3), (4.5 / 5.6) ^ 2), appliedGain(out3))

	tool:set("Force", 1)
	local _, out4 = tool:process(meta({ lens_type = "Nikon 50mm", aperture = "f4.5" }), 5)
	check("a new force setting is noticed", appliedGain(out4) ~= nil)

	local _, out5 = tool:process(meta({ GammaSpace = { Gamma = 2.2 } }), 6)
	check("a new gamma is noticed", appliedGain(out5) == nil)
end

tap.section("reporting")
do
	local tool = newTool()
	local first = tool:process(meta(), 1)
	check("reports the first frame", first ~= nil)

	local second = tool:process(meta(), 2)
	check("silent while nothing changes", second == nil, second)

	local third = tool:process(meta({ aperture = "f4.5" }), 3)
	check("reports when the aperture ramps", contains(third, "f4.5"), third)
end

do
	local tool = newTool()
	tool:set("Report", 1)                 -- Every Frame
	local a = tool:process(meta(), 1)
	local b = tool:process(meta(), 2)
	check("Every Frame always reports", a ~= nil and b ~= nil)
	check("and numbers the frames", contains(b, "frame 2"), b)
end

do
	local tool = newTool()
	tool:set("ConsoleLogging", 0)
	local report, out = tool:process(meta(), 1)
	check("Console Logging off stays silent", report == nil, report)
	check("but still corrects", appliedGain(out) ~= nil)
end

tap.section("zoom position")
do
	local tool = newTool()
	local report = tool:process(meta(), 1)
	check("reports the focal length", contains(report, "zoom       : 10mm"), report)
	check("and the focus distance", contains(report, "focus 2240mm to 6480mm"), report)

	-- The whole point: the aperture is quantised but the zoom is not, so a
	-- ramp must report at every distinct focal length, not only where the
	-- reported f-number happens to step.
	local same = tool:process(meta(), 2)
	check("silent while the zoom holds", same == nil, same)

	local moved = tool:process(meta({ focal_length = "12mm" }), 3)
	check("reports when the zoom moves at a constant aperture",
		contains(moved, "zoom       : 12mm"), moved)

	local focused = tool:process(meta({ focal_length = "12mm", distance = "1000mm to 2000mm" }), 4)
	check("reports when the focus distance moves", focused ~= nil, focused)
end

do
	-- A pass-through still says where the lens was, which is what makes the
	-- skipped frames useful when working out a correction curve.
	local tool = newTool()
	local report = tool:process(meta({ aperture = "f4" }), 1)
	check("zoom is reported on a pass-through too",
		contains(report, "zoom       : 10mm"), report)
end

tap.section("the reported aperture is quantised, the lens is not")
do
	-- The camera keeps saying f/3.5 out to 12mm, but the lens has ramped to
	-- f/3.7 by then and the frame is correspondingly darker. The database
	-- knows that; the metadata doesn't.
	local tool = newTool()
	local report, out = tool:process(meta({ focal_length = "12mm" }), 1)

	check("corrects from what the lens can actually do",
		near(appliedGain(out), (3.7 / 4) ^ 2), appliedGain(out))
	check("not from the f-number the camera reported",
		not near(appliedGain(out), (3.5 / 4) ^ 2))
	check("shows the aperture it used", contains(report, "aperture   : f3.7 -> target f4"), report)
	check("and says the camera disagreed", contains(report, "f3.5 reported"), report)
	check("naming the zoom position that settles it", contains(report, "only opens to f3.7 at 12mm"),
		report)
end

do
	-- Only the entries at 10, 11, 12, 13, 15 and 17mm were observed; the rest
	-- of the ramp is filled in between them.
	local tool = newTool()
	local _, out = tool:process(meta({ focal_length = "14mm" }), 1)
	check("interpolates between the measured positions",
		near(appliedGain(out), (3.9 / 4) ^ 2), appliedGain(out))

	local _, out2 = tool:process(meta({ focal_length = "16mm" }), 2)
	check("and again further along", near(appliedGain(out2), (4.1 / 4) ^ 2), appliedGain(out2))
end

do
	-- Past the end of the table the widest aperture is held flat rather than
	-- extrapolated, which is what the lens does too once it is wide open.
	local tool = newTool()
	local _, out = tool:process(meta({ focal_length = "22mm" }), 1)
	check("holds at the long end", near(appliedGain(out), (4.5 / 4) ^ 2), appliedGain(out))

	local _, out2 = tool:process(meta({ focal_length = "30mm" }), 2)
	check("and does not extrapolate past it", near(appliedGain(out2), (4.5 / 4) ^ 2), appliedGain(out2))
end

do
	-- At the wide end the metadata is already right, so nothing is overruled
	-- and the report has nothing extra to say.
	local tool = newTool()
	local report, out = tool:process(meta({ focal_length = "10mm" }), 1)
	check("leaves the wide end alone", near(appliedGain(out), 0.765625), appliedGain(out))
	check("and says nothing about it", not contains(report, "wide open"), report)
end

do
	-- The table is a floor on the f-number, not a replacement for it: stopped
	-- down, the reported aperture is reachable and therefore believed.
	local tool = newTool()
	local report, out = tool:process(meta({ focal_length = "12mm", aperture = "f8" }), 1)
	check("a stopped-down frame is corrected from its own aperture",
		near(appliedGain(out), (8 / 4) ^ 2), appliedGain(out))
	check("with nothing overruled", not contains(report, "reported"), report)
end

do
	-- Zooming at a constant reported aperture changes the correction, which is
	-- the entire point -- and the cache has to notice.
	local tool = newTool()
	local _, out = tool:process(meta({ focal_length = "11mm" }), 1)
	check("zoom alone moves the correction", near(appliedGain(out), (3.6 / 4) ^ 2), appliedGain(out))

	local _, out2 = tool:process(meta({ focal_length = "13mm" }), 2)
	check("and moves it again", near(appliedGain(out2), (3.8 / 4) ^ 2), appliedGain(out2))
end

do
	-- No focal length is no lookup; fall back to what the camera said.
	local tool = newTool()
	local _, out = tool:process(meta({ focal_length = "<nil>" }), 1)
	check("without a focal length the reported aperture stands",
		near(appliedGain(out), 0.765625), appliedGain(out))
end

do
	-- A forced lens has no table to consult, so forcing cannot invent one.
	local tool = newTool()
	tool:set("Force", 1)
	local _, out = tool:process(meta({
		lens_type = "Sigma 18-35mm f/1.8 DC HSM", focal_length = "12mm" }), 1)
	check("an unlisted lens is corrected from its metadata alone",
		near(appliedGain(out), 0.765625), appliedGain(out))
end

do
	-- Both f-numbers reach the stamp, so a downstream tool can see that they
	-- differed and by how much.
	local tool = newTool()
	local _, out = tool:process(meta({ focal_length = "12mm" }), 1)
	local stamped = out.Metadata.aperture_normalize
	check("stamps the aperture it corrected from", stamped and stamped.from == "f3.7",
		stamped and stamped.from)
	check("and the one the camera reported", stamped and stamped.reported == "f3.5",
		stamped and stamped.reported)

	local tool2 = newTool()
	local _, out2 = tool2:process(meta(), 1)
	check("and leaves it out when they agree",
		out2.Metadata.aperture_normalize.reported == nil,
		out2.Metadata.aperture_normalize.reported)
end

tap.section("normalising to the lens's widest aperture")
do
	-- The shipped default: aim at the widest aperture the lens has, so the
	-- clip matches its own wide end and every correction brightens.
	local tool = newDefaultTool()
	check("the control is on by default",
		tool.AutoTarget.Attrs.INP_Default == 1.0, tool.AutoTarget.Attrs.INP_Default)

	local report, out = tool:process(meta({ focal_length = "12mm" }), 1)
	check("targets f/3.5 rather than the slider's f/4",
		near(appliedGain(out), (3.7 / 3.5) ^ 2), appliedGain(out))
	check("says what it targeted", contains(report, "-> target f3.5"), report)
	check("and where that came from", contains(report, "the widest this lens opens"), report)
end

do
	-- At the wide end there is nothing left to undo, since that is where the
	-- target came from.
	local tool = newDefaultTool()
	local _, out = tool:process(meta(), 1)
	check("the wide end needs no correction", near(appliedGain(out), 1.0), appliedGain(out))
end

do
	-- Across the zoom range every correction brightens, which is the point of
	-- picking the widest: the tool never has to throw light away.
	local tool = newDefaultTool()
	for _, focal in ipairs({ "13mm", "17mm", "22mm" }) do
		local _, out = tool:process(meta({ focal_length = focal }), 1)
		check("brightens at " .. focal, appliedGain(out) > 1.0, appliedGain(out))
	end

	local _, out = tool:process(meta({ focal_length = "22mm" }), 2)
	check("the long end is a full 0.725 stops",
		near(appliedGain(out), (4.5 / 3.5) ^ 2), appliedGain(out))
end

do
	-- Turning it off puts the slider back in charge.
	local tool = newDefaultTool()
	tool:set("AutoTarget", 0)
	local report, out = tool:process(meta({ focal_length = "12mm" }), 1)
	check("the slider takes over", near(appliedGain(out), (3.7 / 4) ^ 2), appliedGain(out))
	check("and it stops claiming the lens chose", not contains(report, "widest this lens opens"),
		report)
end

do
	-- An unlisted lens has no widest to aim at, so the slider stands in even
	-- with the control on. Forcing grants permission, not data.
	local tool = newDefaultTool()
	tool:set("Force", 1)
	local report, out = tool:process(meta({ lens_type = "Sigma 18-35mm f/1.8 DC HSM" }), 1)
	check("an unlisted lens falls back to the slider",
		near(appliedGain(out), 0.765625), appliedGain(out))
	check("and does not pretend otherwise", not contains(report, "widest this lens opens"), report)
end

do
	-- The cache has to notice the control, like every other input.
	local tool = newDefaultTool()
	local _, out = tool:process(meta({ focal_length = "12mm" }), 1)
	check("follows the lens first", near(appliedGain(out), (3.7 / 3.5) ^ 2), appliedGain(out))

	tool:set("AutoTarget", 0)
	local _, out2 = tool:process(meta({ focal_length = "12mm" }), 2)
	check("and notices when it is switched off", near(appliedGain(out2), (3.7 / 4) ^ 2),
		appliedGain(out2))
end

tap.section("Generate Report")
do
	local TMP = "test/tmp"
	os.execute("rm -rf " .. TMP)

	local function readFile(path)
		local f = io.open(path, "r")
		if not f then return nil end
		local s = f:read("*a")
		f:close()
		return s
	end

	local tool = newTool()
	tool:set("ReportDir", TMP .. "/reports")
	tool:press("GenerateReport")
	tool:process(meta(), 7)

	local written = readFile(TMP .. "/reports/aperture-normalize-A067_08211340_C007-7.txt")
	check("writes a file named for the clip and frame", written ~= nil)
	check("records the settings", contains(written, "target aperture         : f4"), written)
	check("records which target was chosen",
		contains(written, "target the lens's widest: no"), written)
	check("records the outcome", contains(written, "correction : -0.3853 stops"), written)
	check("dumps the metadata", contains(written, "lens_type = " .. LENS), written)
	check("shows the zoom in the outcome", contains(written, "zoom       : 10mm"), written)
	check("flattens nested metadata", contains(written, "GammaSpace.Gamma = 1"), written)

	-- One press, one report.
	local before = #tool.printed
	tool:process(meta(), 8)
	check("does not keep writing every frame",
		readFile(TMP .. "/reports/aperture-normalize-A067_08211340_C007-8.txt") == nil)

	-- A skipped frame is worth a report too -- that is when you most want one.
	local tool2 = newTool()
	tool2:set("ReportDir", TMP .. "/reports")
	tool2:press("GenerateReport")
	tool2:process(meta({ lens_type = "Sigma 18-35mm f/1.8 DC HSM" }), 9)
	local skipped = readFile(TMP .. "/reports/aperture-normalize-A067_08211340_C007-9.txt")
	check("reports a pass-through and why", contains(skipped, "passed through, because"), skipped)

	-- With the target following the lens, the slider is still recorded, but
	-- saying so without saying it went unused would be misleading.
	local tool4 = newDefaultTool()
	tool4:set("ReportDir", TMP .. "/reports")
	tool4:press("GenerateReport")
	tool4:process(meta({ focal_length = "12mm" }), 11)
	local auto = readFile(TMP .. "/reports/aperture-normalize-A067_08211340_C007-11.txt")
	check("records that the lens chose the target",
		contains(auto, "target the lens's widest: yes"), auto)
	check("and that the slider went unused", contains(auto, "unused"), auto)

	-- No folder set is a mistake worth naming.
	local tool3 = newTool()
	tool3:press("GenerateReport")
	local report = tool3:process(meta(), 1)
	check("asks for a folder when none is set",
		contains(tool3.printed[#tool3.printed], "set a Report Folder first"),
		tool3.printed[#tool3.printed])

	os.execute("rm -rf " .. TMP)
end

tap.finish()
