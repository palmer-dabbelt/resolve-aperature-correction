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

local function newTool()
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
		GammaSpace = { Gamma = 1 },
	}
	for k, v in pairs(over or {}) do
		if v == "<nil>" then v = nil end
		m[k] = v
	end
	return m
end

-- The gain a correcting frame applied, or nil if it passed through.
local function appliedGain(out)
	return out.channelOp and out.channelOp.options and out.channelOp.options.R
end

local function checkPassThrough(label, metadata, tool)
	tool = tool or newTool()
	local report, out, img = tool:process(metadata, 1)
	check(label .. ": output is the input", out == img, report)
	check(label .. ": nothing was applied", out.channelOp == nil)
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

	check("output is a new image", out ~= img and out.copiedFrom == img)
	check("multiplies in a single pass", out.channelOp and out.channelOp.operation == "Multiply",
		out.channelOp and out.channelOp.operation)
	check("gain is (3.5/4)^2", near(appliedGain(out), 0.765625), appliedGain(out))
	check("applied equally to R, G and B",
		out.channelOp.options.R == out.channelOp.options.G and
		out.channelOp.options.G == out.channelOp.options.B)
	check("alpha is left out entirely", out.channelOp.options.A == nil)
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
	check("absurd correction is refused", out == img and out.channelOp == nil, report)
	check("says why", contains(report, "too large"), report)
end

tap.section("a correction too small to see is not worth a copy")
do
	local r = checkPassThrough("already at the target", meta({ aperture = "f4" }))
	check("says it is already there", contains(r, "already at the target aperture"), r)
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
	check("a new gamma is noticed", out5.channelOp == nil)
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
	tool:set("Report", 2)                 -- Never
	local report, out = tool:process(meta(), 1)
	check("Never stays silent", report == nil, report)
	check("but still corrects", appliedGain(out) ~= nil)
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
	check("records the settings", contains(written, "target aperture        : f4"), written)
	check("records the outcome", contains(written, "correction : -0.3853 stops"), written)
	check("dumps the metadata", contains(written, "lens_type = " .. LENS), written)
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
