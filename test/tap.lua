--[[--
The small amount of scaffolding the test files share: a pass/fail tally, and
the two assertions that come up over and over.
--]]--

local tap = {
	passed = 0,
	failed = 0,
}

function tap.section(name)
	print(name)
end

function tap.check(name, ok, detail)
	if ok then
		tap.passed = tap.passed + 1
		print("  ok    " .. name)
	else
		tap.failed = tap.failed + 1
		print("  FAIL  " .. name .. (detail and ("\n        " .. tostring(detail)) or ""))
	end
end

function tap.contains(haystack, needle)
	return haystack ~= nil and haystack:find(needle, 1, true) ~= nil
end

-- Compares floats without inviting a rounding argument.
function tap.near(a, b, tolerance)
	if type(a) ~= "number" or type(b) ~= "number" then return false end
	return math.abs(a - b) <= (tolerance or 1e-6)
end

function tap.finish()
	print("")
	print(string.format("%d passed, %d failed", tap.passed, tap.failed))
	os.exit(tap.failed == 0 and 0 or 1)
end

return tap
