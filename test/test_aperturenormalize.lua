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

-- BRAW-ish metadata, with any field overridable per test.
local function meta(over)
	local m = {
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

-- Asserts the frame was passed through untouched.
local function checkPassThrough(label, metadata, tool)
	tool = tool or newTool()
	local report, out, img = tool:process(metadata, 1)
	check(label .. ": output is the input", out == img, report)
	check(label .. ": no gain applied", #img.gains == 0)
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

	check("output is a copy, not the input", out ~= img and out.copiedFrom == img)
	check("gain applied once", #out.gains == 1, #out.gains)
	check("gain is (3.5/4)^2", near(out.gains[1].r, 0.765625), out.gains[1] and out.gains[1].r)
	check("applied equally to R, G and B",
		out.gains[1].r == out.gains[1].g and out.gains[1].g == out.gains[1].b)
	check("alpha is left alone", out.gains[1].a == 1.0, out.gains[1] and out.gains[1].a)
	check("reports the stops", contains(report, "-0.385 stops"), report)
	check("names the lens", contains(report, LENS), report)
end

do
	-- f/4.5 is dimmer than f/4, so normalising brightens.
	local tool = newTool()
	local _, out = tool:process(meta({ aperture = "f4.5" }), 1)
	check("f/4.5 brightens", near(out.gains[1].r, (4.5 / 4) ^ 2), out.gains[1].r)
end

do
	-- Already at the target: a no-op correction, but still a real one.
	local tool = newTool()
	local report, out = tool:process(meta({ aperture = "f4" }), 1)
	check("f/4 to f/4 is unity gain", near(out.gains[1].r, 1.0), out.gains[1].r)
	check("and reports zero stops", contains(report, "+0.000 stops"), report)
end

tap.section("target aperture")
do
	local tool = newTool()
	tool:set("TargetAperture", 5.6)
	local _, out = tool:process(meta(), 1)
	check("honours a different target", near(out.gains[1].r, (3.5 / 5.6) ^ 2), out.gains[1].r)
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
		check('reads "' .. written .. '"',
			out.gains[1] ~= nil and near(out.gains[1].r, 0.765625),
			out.gains[1] and out.gains[1].r)
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

	-- A gain is only valid on linear light.
	r = checkPassThrough("non-linear image", meta({ GammaSpace = { Gamma = 2.2 } }))
	check("mentions the gamma", contains(r, "2.2"), r)
end

do
	-- A correction this big means the metadata is lying, not that the shot
	-- needs three and a half stops.
	local tool = newTool()
	tool:set("TargetAperture", 0.5)
	local report, out, img = tool:process(meta({ aperture = "f29" }), 1)
	check("absurd correction is refused", out == img and #img.gains == 0, report)
	check("says why", contains(report, "too large"), report)
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
		check("matches " .. string.format("%q", spelling), out.gains[1] ~= nil)
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
	check("keeps the original fields", out.Metadata.focal_length == "10mm")

	check("does not mutate the input's metadata", input.aperture_normalize == nil)
	check("input image metadata untouched", img.Metadata.aperture_normalize == nil)
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
	check("but still corrects", out.gains[1] ~= nil)
end

tap.finish()
