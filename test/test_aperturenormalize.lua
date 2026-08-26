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

-- The tool fills the Target Aperture control in with the lens's widest the
-- first time it sees a lens it knows -- but only over the factory default or a
-- value it wrote itself. So a test that pins the target to anything else keeps
-- it, which is what most of what follows wants: arithmetic reads better
-- against a target that stays put. f/3.5 taken to f/5.6 is exactly 0.390625.
local TEST_TARGET = 5.6
local TEST_GAIN = (3.5 / 5.6) ^ 2

-- Console Logging ships on Errors, which says nothing at all about a frame it
-- corrected. Most of what follows wants to read the report, so it asks for
-- Corrections -- the mode that used to be the only one there was.
local function newTool(target)
	local tool = harness.load(FUSE)
	tool:set("TargetAperture", target or TEST_TARGET)
	tool:set("ConsoleLogging", 2)
	return tool
end

-- The tool as it ships, target still at the factory default and so still up
-- for grabs. The "filling in the target" section is where that is tested.
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
	-- f/3.5 normalised to f/5.6 is (3.5/5.6)^2 = 0.390625, i.e. it darkens.
	local tool = newTool()
	local report, out, img = tool:process(meta(), 1)

	check("output is a new image", out ~= img)
	check("gain is (3.5/5.6)^2", near(appliedGain(out), TEST_GAIN), appliedGain(out))
	check("reports the stops", contains(report, "-1.356 stops"), report)
	check("names the lens", contains(report, LENS), report)
end

do
	-- f/4.5 is nearer f/5.6 than f/3.5 is, so it darkens less.
	local tool = newTool()
	local _, out = tool:process(meta({ aperture = "f4.5" }), 1)
	check("f/4.5 darkens less", near(appliedGain(out), (4.5 / TEST_TARGET) ^ 2), appliedGain(out))
end

tap.section("target aperture")
do
	local tool = newTool()
	tool:set("TargetAperture", 8)
	local _, out = tool:process(meta(), 1)
	check("honours a different target", near(appliedGain(out), (3.5 / 8) ^ 2), appliedGain(out))
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
		check('reads "' .. written .. '"', near(appliedGain(out), TEST_GAIN), appliedGain(out))
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
	local report, out, img = tool:process(meta({ aperture = "f5.6" }), 1)

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
	check("corrects an unlisted lens", near(appliedGain(out), TEST_GAIN), appliedGain(out))
	check("says the correction was forced", contains(report, "forced"), report)
	check("still names the lens", contains(report, "Sigma 18-35mm f/1.8 DC HSM"), report)
end

do
	local tool = newTool()
	tool:set("Force", 1)
	local report, out = tool:process(meta({ lens_type = "<nil>" }), 1)
	check("covers metadata with no lens at all", near(appliedGain(out), TEST_GAIN), appliedGain(out))
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
	check("handed the kernel the gain", near(out.gpu.gain, TEST_GAIN), out.gpu.gain)
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
	check("copy+gain applies the same gain", near(appliedGain(out), TEST_GAIN), appliedGain(out))
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
		near(out.channelOp.options.R, TEST_GAIN), out.channelOp.options.R)
	check("channel op leaves alpha out entirely", out.channelOp.options.A == nil)
end

do
	-- A host with no GPU falls back rather than failing.
	local tool = newTool()
	tool.gpuAvailable = false
	local report, out = tool:process(meta(), 1)

	check("falls back to the CPU", out.gpu == nil and near(appliedGain(out), TEST_GAIN), appliedGain(out))
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
		out.gpu == nil and near(appliedGain(out), TEST_GAIN), appliedGain(out))
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
		near(tool.out.Gain.Value, TEST_GAIN), tool.out.Gain.Value)
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
		near(tool.out.Gain.Value, TEST_GAIN), tool.out.Gain.Value)
	check("and no metadata stamp, which would need the copy",
		out.Metadata.aperture_normalize == nil)
end

do
	-- Reporting is independent of who applies the gain.
	local tool = newTool()
	tool:set("Processing", 3)
	local report = tool:process(meta(), 1)
	check("still reports the correction", contains(report, "0.3906"), report)
end

tap.section("metadata stamping")
do
	local tool = newTool()
	local input = meta()
	local _, out, img = tool:process(input, 1)

	local stamped = out.Metadata.aperture_normalize
	check("stamps the output", type(stamped) == "table")
	check("records the gain", stamped and near(tonumber(stamped.gain), TEST_GAIN), stamped and stamped.gain)
	check("records the source aperture", stamped and stamped.from == "f3.5", stamped and stamped.from)
	check("records the target", stamped and stamped.target == "f5.6", stamped and stamped.target)
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
	check("same inputs still correct on later frames", near(appliedGain(out), TEST_GAIN), appliedGain(out))

	-- Changing an input the decision depends on must invalidate the cache.
	local _, out2 = tool:process(meta({ aperture = "f4.5" }), 3)
	check("a new aperture is noticed", near(appliedGain(out2), (4.5 / TEST_TARGET) ^ 2), appliedGain(out2))

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
		near(appliedGain(out), (3.7 / TEST_TARGET) ^ 2), appliedGain(out))
	check("not from the f-number the camera reported",
		not near(appliedGain(out), (3.5 / TEST_TARGET) ^ 2))
	check("shows the aperture it used", contains(report, "aperture   : f3.7 -> target f5.6"), report)
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
		near(appliedGain(out), (3.9 / TEST_TARGET) ^ 2), appliedGain(out))

	local _, out2 = tool:process(meta({ focal_length = "16mm" }), 2)
	check("and again further along", near(appliedGain(out2), (4.1 / TEST_TARGET) ^ 2), appliedGain(out2))
end

do
	-- Past the end of the table the widest aperture is held flat rather than
	-- extrapolated, which is what the lens does too once it is wide open.
	local tool = newTool()
	local _, out = tool:process(meta({ focal_length = "22mm" }), 1)
	check("holds at the long end", near(appliedGain(out), (4.5 / TEST_TARGET) ^ 2), appliedGain(out))

	local _, out2 = tool:process(meta({ focal_length = "30mm" }), 2)
	check("and does not extrapolate past it", near(appliedGain(out2), (4.5 / TEST_TARGET) ^ 2), appliedGain(out2))
end

do
	-- At the wide end the metadata is already right, so nothing is overruled
	-- and the report has nothing extra to say.
	local tool = newTool()
	local report, out = tool:process(meta({ focal_length = "10mm" }), 1)
	check("leaves the wide end alone", near(appliedGain(out), TEST_GAIN), appliedGain(out))
	check("and says nothing about it", not contains(report, "wide open"), report)
end

do
	-- The table is a floor on the f-number, not a replacement for it: stopped
	-- down, the reported aperture is reachable and therefore believed.
	local tool = newTool()
	local report, out = tool:process(meta({ focal_length = "12mm", aperture = "f8" }), 1)
	check("a stopped-down frame is corrected from its own aperture",
		near(appliedGain(out), (8 / TEST_TARGET) ^ 2), appliedGain(out))
	check("with nothing overruled", not contains(report, "reported"), report)
end

do
	-- Zooming at a constant reported aperture changes the correction, which is
	-- the entire point -- and the cache has to notice.
	local tool = newTool()
	local _, out = tool:process(meta({ focal_length = "11mm" }), 1)
	check("zoom alone moves the correction", near(appliedGain(out), (3.6 / TEST_TARGET) ^ 2), appliedGain(out))

	local _, out2 = tool:process(meta({ focal_length = "13mm" }), 2)
	check("and moves it again", near(appliedGain(out2), (3.8 / TEST_TARGET) ^ 2), appliedGain(out2))
end

do
	-- No focal length is no lookup; fall back to what the camera said.
	local tool = newTool()
	local _, out = tool:process(meta({ focal_length = "<nil>" }), 1)
	check("without a focal length the reported aperture stands",
		near(appliedGain(out), TEST_GAIN), appliedGain(out))
end

do
	-- A forced lens has no table to consult, so forcing cannot invent one.
	local tool = newTool()
	tool:set("Force", 1)
	local _, out = tool:process(meta({
		lens_type = "Sigma 18-35mm f/1.8 DC HSM", focal_length = "12mm" }), 1)
	check("an unlisted lens is corrected from its metadata alone",
		near(appliedGain(out), TEST_GAIN), appliedGain(out))
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

tap.section("filling in the target aperture")
do
	-- The lens turns up, and the slider it would have had to be set to by
	-- hand gets set for you.
	local tool = newDefaultTool()
	check("the slider ships at f/4", tool.TargetAperture.value == 4.0, tool.TargetAperture.value)

	local _, out = tool:process(meta({ focal_length = "12mm" }), 1)
	check("the lens's widest is written into it", tool.TargetAperture.value == 3.5,
		tool.TargetAperture.value)
	check("and it was written, not merely assumed",
		tool.TargetAperture.sourced[1] == 3.5, tool.TargetAperture.sourced[1])
	check("the frame is corrected to it straight away",
		near(appliedGain(out), (3.7 / 3.5) ^ 2), appliedGain(out))
end

do
	-- Once it is filled in, it stays filled in rather than being rewritten
	-- every frame.
	local tool = newDefaultTool()
	tool:process(meta(), 1)
	tool:process(meta({ focal_length = "13mm" }), 2)
	tool:process(meta({ focal_length = "15mm" }), 3)
	check("written once, not per frame", #tool.TargetAperture.sourced == 1,
		#tool.TargetAperture.sourced)
end

do
	-- The hazard this has to avoid: a comp where somebody chose a target.
	local tool = newDefaultTool()
	tool:set("TargetAperture", 5.6)
	local _, out = tool:process(meta(), 1)

	check("a chosen target is left alone", tool.TargetAperture.value == 5.6,
		tool.TargetAperture.value)
	check("nothing was written at all", #tool.TargetAperture.sourced == 0)
	check("and it is what the frame was corrected to", near(appliedGain(out), TEST_GAIN),
		appliedGain(out))
end

do
	-- A second lens turning up mid-timeline. This one is not in the database,
	-- so there is no widest to fill in from and the first lens's answer
	-- stands -- which is the right outcome, but not the same as the tool
	-- having decided to leave it alone.
	local tool = newDefaultTool()
	tool:process(meta(), 1)
	check("filled in for the first lens", tool.TargetAperture.value == 3.5,
		tool.TargetAperture.value)

	tool:process(meta({ lens_type = "Sigma 18-35mm f/1.8 DC HSM" }), 2)
	check("an unlisted lens has no widest, so nothing is rewritten",
		tool.TargetAperture.value == 3.5, tool.TargetAperture.value)
end

do
	-- Nothing to fill in from, and nothing broken by that.
	local tool = newDefaultTool()
	tool:process(meta({ lens_type = "<nil>" }), 1)
	check("no lens leaves the slider at its default", tool.TargetAperture.value == 4.0,
		tool.TargetAperture.value)
	check("and writes nothing", #tool.TargetAperture.sourced == 0)
end

tap.section("Console Logging: Errors")
do
	-- The shipped default. A clip it understands says nothing whatsoever.
	local tool = newDefaultTool()
	local report = tool:process(meta({ focal_length = "12mm" }), 1)
	check("a corrected frame is silent", report == nil, report)
	check("nothing was printed at all", #tool.printed == 0, tool.printed[1])
end

do
	-- A frame it declines to correct is exactly what this mode is for.
	local tool = newDefaultTool()
	local report = tool:process(meta({ lens_type = "Sigma 18-35mm f/1.8 DC HSM" }), 1)
	check("a pass-through is reported", contains(report, "passing through"), report)
	check("and says why", contains(report, "not in the lens database"), report)
end

do
	-- "Only once" means once per reason, including across a zoom -- which is
	-- the difference from Corrections, where the zoom is part of what counts
	-- as a change.
	local tool = newDefaultTool()
	local unknown = { lens_type = "Sigma 18-35mm f/1.8 DC HSM" }
	tool:process(meta(unknown), 1)
	local before = #tool.printed

	for frame = 2, 6 do
		unknown.focal_length = (10 + frame) .. "mm"
		tool:process(meta(unknown), frame)
	end
	check("said once, not once per frame", #tool.printed == before, #tool.printed - before)

	-- A different reason is a different thing to say.
	tool:process(meta({ GammaSpace = { Gamma = 2.2 } }), 7)
	check("but a new reason is still worth saying", #tool.printed == before + 1)
	check("and it is the new one", contains(tool.printed[#tool.printed], "gamma"),
		tool.printed[#tool.printed])
end

do
	-- None means none, even for the things Errors would report.
	local tool = newDefaultTool()
	tool:set("ConsoleLogging", 0)
	local report, out, img = tool:process(meta({ lens_type = "Nobody's Lens" }), 1)
	check("None stays silent about pass-throughs", report == nil, report)
	check("but still passes the frame through", out == img)
end

tap.section("Console Logging: All Metadata")
do
	local tool = newTool()
	tool:set("ConsoleLogging", 3)
	local report = tool:process(meta(), 1)

	check("still reports the correction", contains(report, "correction :"), report)
	check("and lists the fields", contains(report, "metadata   :"), report)
	check("including ones the correction ignores",
		contains(report, "Filename") and contains(report, "/clips/A067_08211340_C007.braw"), report)
	check("flattening nested ones", contains(report, "GammaSpace.Gamma = 1"), report)
	check("and counting them", contains(report, "6 field(s)"), report)
	check("nothing is marked on the first frame, having nothing to compare to",
		not contains(report, "*"), report)
end

do
	-- The point of the mode: a field that moves gets marked, so it can be
	-- picked out of a screenful of fields that didn't.
	local tool = newTool()
	tool:set("ConsoleLogging", 3)
	tool:process(meta(), 1)
	local report = tool:process(meta({ aperture = "f4.5" }), 2)

	check("says how many moved", contains(report, "1 changed since frame 1"), report)
	check("marks the one that did", contains(report, "* aperture"), report)
	check("and shows what it was", contains(report, "(was f3.5)"), report)
	check("leaving the rest unmarked", contains(report, "  focal_length"), report)
end

do
	-- The reason this mode exists: a field nothing else looks at, ticking
	-- while the zoom and the aperture sit still. Corrections would never
	-- report this frame, because nothing it computes from has moved.
	local tool = newTool()
	tool:set("ConsoleLogging", 2)
	tool:process(meta({ zoom_encoder = "4821" }), 1)
	local quiet = tool:process(meta({ zoom_encoder = "4837" }), 2)
	check("Corrections cannot see it move", quiet == nil, quiet)

	local tool2 = newTool()
	tool2:set("ConsoleLogging", 3)
	tool2:process(meta({ zoom_encoder = "4821" }), 1)
	local found = tool2:process(meta({ zoom_encoder = "4837" }), 2)
	check("All Metadata does", contains(found, "* zoom_encoder"), found)
	check("with both values", contains(found, "4837") and contains(found, "(was 4821)"), found)
end

do
	-- Fields coming and going are marked too.
	local tool = newTool()
	tool:set("ConsoleLogging", 3)
	tool:process(meta(), 1)

	local appeared = tool:process(meta({ zoom_encoder = "4821" }), 2)
	check("a new field is marked as new", contains(appeared, "+ zoom_encoder"), appeared)

	local gone = tool:process(meta(), 3)
	check("and a departed one as gone", contains(gone, "- zoom_encoder"), gone)
	check("saying what it had been", contains(gone, "was 4821"), gone)
end

do
	-- Metadata that isn't there at all is a fact worth printing rather than
	-- an error.
	local tool = newTool()
	tool:set("ConsoleLogging", 3)
	local report = tool:process(nil, 1)
	check("says there is none", contains(report, "metadata   : none"), report)
end

tap.finish()
