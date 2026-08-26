--[[--
Syntax-checks the files named on the command line by compiling them without
running them. Used by "make check" so a fuse that won't parse never reaches
Resolve's Fuses directory.
--]]--

local bad = 0

for i = 1, #arg do
	local chunk, err = loadfile(arg[i])
	if chunk then
		print("ok    " .. arg[i])
	else
		io.stderr:write("FAIL  " .. tostring(err) .. "\n")
		bad = bad + 1
	end
end

if #arg == 0 then
	io.stderr:write("usage: syntax.lua FILE...\n")
	os.exit(1)
end

os.exit(bad == 0 and 0 or 1)
