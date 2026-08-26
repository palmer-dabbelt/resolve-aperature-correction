--[[--
Tests for ApertureProbe's reporting logic.

Run with:  lua test/test_apertureprobe.lua   (from the repository root)
--]]--

package.path = "test/?.lua;" .. package.path
local harness = require("harness")

local FUSE = "Fuses/ApertureProbe.fuse"

local passed, failed = 0, 0

local function check(name, ok, detail)
	if ok then
		passed = passed + 1
		print("  ok    " .. name)
	else
		failed = failed + 1
		print("  FAIL  " .. name .. (detail and ("\n        " .. tostring(detail)) or ""))
	end
end

local function contains(haystack, needle)
	return haystack ~= nil and haystack:find(needle, 1, true) ~= nil
end

local function newProbe()
	return harness.load(FUSE)
end

print("registration")
do
	local probe = newProbe()
	local reg = probe.registration
	check("registers a CT_Tool", reg ~= nil and reg.classtype == "CT_Tool", reg and reg.classtype)
	check("class name is ApertureProbe", reg and reg.name == "ApertureProbe", reg and reg.name)
	check("has a display name", reg and reg.attrs.REGS_Name == "Aperture Probe")
end

print("pass-through")
do
	local probe = newProbe()
	local _, out, img = probe:process({ Filename = "/clips/a.braw" }, 1)
	check("output is the input image, untouched", out == img)
end

print("no metadata")
do
	local probe = newProbe()
	local report = probe:process(nil, 1)
	check("says metadata is nil", contains(report, "no metadata at all"), report)

	local probe2 = newProbe()
	local report2 = probe2:process({}, 1)
	check("says table is empty", contains(report2, "metadata table present but empty"), report2)
end

print("aperture detection")
do
	local probe = newProbe()
	local report = probe:process({ Aperture = "4.0", Filename = "/clips/a.braw" }, 7)
	check("reports the frame number", contains(report, "frame 7"), report)
	check("finds Aperture", contains(report, "APERTURE:") and contains(report, "Aperture = 4.0"), report)
	check("does not claim none found", not contains(report, "none found"), report)
	check("files Filename under everything else",
		contains(report, "everything else:") and contains(report, "Filename = /clips/a.braw"), report)
end

print("key normalisation")
do
	-- These should all be recognised as the aperture despite the spelling.
	for _, key in ipairs({ "F-Number", "f_stop", "FNumber", "fstop", "T-Stop", "IrisValue", "ApertureValue" }) do
		local probe = newProbe()
		local report = probe:process({ [key] = "2.8" }, 1)
		check("matches " .. key, contains(report, "APERTURE:") and contains(report, key .. " = 2.8"), report)
	end

	-- ...and these should not be mistaken for it.
	for _, key in ipairs({ "Vendor", "Average", "Filename", "TimeCode" }) do
		local probe = newProbe()
		local report = probe:process({ [key] = "x" }, 1)
		check("does not match " .. key, contains(report, "APERTURE: none found"), report)
	end
end

print("lens / exposure fields")
do
	local probe = newProbe()
	local report = probe:process({ ISO = "800", ShutterAngle = "180", Filename = "/a.braw" }, 1)
	check("groups lens/exposure fields", contains(report, "lens / exposure:"), report)
	check("lists ISO", contains(report, "ISO = 800"), report)
	check("lists ShutterAngle", contains(report, "ShutterAngle = 180"), report)
	check("still says aperture missing", contains(report, "APERTURE: none found"), report)
end

print("nested metadata")
do
	local probe = newProbe()
	local report = probe:process({ Lens = { FocalLength = "35", Aperture = "1.8" } }, 1)
	check("flattens to dotted paths", contains(report, "Lens.Aperture = 1.8"), report)
	check("nested aperture is detected", contains(report, "APERTURE:"), report)
	check("nested focal length is lens context", contains(report, "Lens.FocalLength = 35"), report)

	local probe2 = newProbe()
	local report2 = probe2:process({ Empty = {} }, 1)
	check("marks empty subtables", contains(report2, "Empty = <empty table>"), report2)
end

print("circular metadata does not hang")
do
	local meta = { Filename = "/a.braw" }
	meta.Self = meta
	local probe = newProbe()
	local report = probe:process(meta, 1)
	check("notes the cycle", contains(report, "<circular reference>"), report)
end

print("report modes")
do
	-- Default mode 0, "When It Changes": TimeCode churn must not re-trigger.
	local probe = newProbe()
	local first = probe:process({ Aperture = "4.0", TimeCode = "01:00:00:01" }, 1)
	check("reports the first frame", first ~= nil, first)

	local second = probe:process({ Aperture = "4.0", TimeCode = "01:00:00:02" }, 2)
	check("silent when only TimeCode moved", second == nil, second)

	local third = probe:process({ Aperture = "5.6", TimeCode = "01:00:00:03" }, 3)
	check("reports when the aperture ramps", contains(third, "Aperture = 5.6"), third)

	local fourth = probe:process({ Aperture = "5.6", TimeCode = "01:00:00:04", NewKey = "x" }, 4)
	check("reports when a new key appears", fourth ~= nil, fourth)

	-- The button clears the remembered signature.
	local fifth = probe:process({ Aperture = "5.6", TimeCode = "01:00:00:05", NewKey = "x" }, 5)
	check("silent again once settled", fifth == nil, fifth)
	probe:reportAgain()
	local sixth = probe:process({ Aperture = "5.6", TimeCode = "01:00:00:06", NewKey = "x" }, 6)
	check("Report Again forces a fresh report", sixth ~= nil, sixth)
end

do
	-- Mode 1, "Every Frame".
	local probe = newProbe()
	probe:set("Report", 1)
	local a = probe:process({ Aperture = "4.0" }, 1)
	local b = probe:process({ Aperture = "4.0" }, 2)
	check("Every Frame always reports", a ~= nil and b ~= nil)
	check("and still numbers the frames", contains(b, "frame 2"), b)
end

do
	-- Mode 2, "Never".
	local probe = newProbe()
	probe:set("Report", 2)
	local report, out, img = probe:process({ Aperture = "4.0" }, 1)
	check("Never stays silent", report == nil, report)
	check("Never still passes the image through", out == img)
end

print("List Every Field")
do
	local probe = newProbe()
	probe:set("DumpAll", 0)
	local report = probe:process({ Aperture = "4.0", Filename = "/a.braw" }, 1)
	check("unrelated fields suppressed", not contains(report, "everything else:"), report)
	check("aperture still shown", contains(report, "Aperture = 4.0"), report)
	check("count still reported", contains(report, "2 field(s) total"), report)
end

--
-- Logging to disk. Off unless a Log Directory is set.
--

local TMP = "test/tmp"
local LOGDIR = TMP .. "/logs"

local function readFile(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function occurrences(hay, needle)
	local n, pos = 0, 1
	while true do
		local s, e = hay:find(needle, pos, true)
		if not s then break end
		n, pos = n + 1, e + 1
	end
	return n
end

local function freshLogDir()
	os.execute("rm -rf " .. TMP)
	return LOGDIR
end

local BRAW = {
	Filename = "/clips/A067_08211340_C007.braw",
	aperture = "f3.5",
	focal_length = "10mm",
	iso = "400",
}

print("logging is opt-in")
do
	freshLogDir()
	local probe = newProbe()
	check("defaults to no log directory", probe.LogDir.value == "", probe.LogDir.value)
	probe:process(BRAW, 1)
	check("writes nothing by default", readFile(LOGDIR .. "/A067_08211340_C007.csv") == nil)
end

print("logging writes csv and log")
do
	freshLogDir()
	local probe = newProbe()
	probe:set("LogDir", LOGDIR)
	probe:process(BRAW, 1)

	local csv = readFile(LOGDIR .. "/A067_08211340_C007.csv")
	local log = readFile(LOGDIR .. "/A067_08211340_C007.log")

	check("creates the directory and the csv", csv ~= nil)
	check("csv has a header", csv and csv:find("frame,field,value", 1, true) == 1, csv)
	check("csv has the aperture row", csv and occurrences(csv, "1,aperture,f3.5") == 1, csv)
	check("csv has the focal length row", csv and occurrences(csv, "1,focal_length,10mm") == 1, csv)
	check("csv names the clip, not the path", csv and occurrences(csv, "1,Filename,") == 1, csv)
	check("writes the log too", log ~= nil and log:find("APERTURE:", 1, true) ~= nil, log)
end

print("log records every frame exactly once")
do
	freshLogDir()
	local probe = newProbe()
	probe:set("LogDir", LOGDIR)
	probe:process(BRAW, 1)
	probe:process(BRAW, 1)          -- a re-render of the same frame
	probe:process(BRAW, 2)

	local csv = readFile(LOGDIR .. "/A067_08211340_C007.csv")
	check("re-rendering a frame does not duplicate it", occurrences(csv, "1,aperture,f3.5") == 1, csv)
	check("a second frame is recorded", occurrences(csv, "2,aperture,f3.5") == 1, csv)
	check("only one header", occurrences(csv, "frame,field,value") == 1, csv)
end

print("log ignores the Report setting")
do
	freshLogDir()
	local probe = newProbe()
	probe:set("LogDir", LOGDIR)
	probe:set("Report", 2)          -- Never: nothing to the Console
	local report = probe:process(BRAW, 1)
	check("Console stays silent", report == nil, report)
	check("but the capture still happens",
		readFile(LOGDIR .. "/A067_08211340_C007.csv") ~= nil)
end

print("csv escaping")
do
	freshLogDir()
	local probe = newProbe()
	probe:set("LogDir", LOGDIR)
	probe:process({ Filename = "/clips/x.braw", notes = 'has, a comma and "quotes"' }, 1)

	local csv = readFile(LOGDIR .. "/x.csv")
	check("quotes fields containing commas",
		csv and csv:find('"has, a comma and ""quotes"""', 1, true) ~= nil, csv)
end

print("clip naming")
do
	freshLogDir()
	local probe = newProbe()
	probe:set("LogDir", LOGDIR)
	probe:process({ aperture = "f3.5" }, 1)   -- no Filename at all
	check("falls back when there is no Filename",
		readFile(LOGDIR .. "/aperture-probe.csv") ~= nil)
end

print("Start Log Over")
do
	freshLogDir()
	local probe = newProbe()
	probe:set("LogDir", LOGDIR)
	probe:process(BRAW, 1)
	probe:process(BRAW, 2)
	probe:press("ResetLog")
	probe:process(BRAW, 1)

	local csv = readFile(LOGDIR .. "/A067_08211340_C007.csv")
	check("truncates rather than appending", occurrences(csv, "2,aperture,f3.5") == 0, csv)
	check("starts again from the header", occurrences(csv, "frame,field,value") == 1, csv)
	check("and records the frame again", occurrences(csv, "1,aperture,f3.5") == 1, csv)
end

os.execute("rm -rf " .. TMP)

print("")
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
