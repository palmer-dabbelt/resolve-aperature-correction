--[[--
A minimal stand-in for the parts of the Fusion Fuse host that ApertureProbe
touches, so the reporting logic can be exercised from a plain Lua interpreter
instead of by clicking around inside Resolve.

It is deliberately thin: it implements AddInput/AddOutput, Input:GetValue,
Output:Set, Request:GetTime and a captured print(). Anything a Fuse does beyond
that is out of scope here.
--]]--

local harness = {}

-- A stand-in Image. Records the Gain() calls made against it so a test can
-- assert on the correction that was applied, and copies like the real thing.
function harness.image(metadata)
	local img = {
		Metadata = metadata,
		gains = {},
	}

	function img:CopyOf()
		local copy = harness.image(self.Metadata)
		copy.copiedFrom = self
		return copy
	end

	function img:Gain(r, g, b, a)
		self.gains[#self.gains + 1] = { r = r, g = g, b = b, a = a }
	end

	return img
end

-- Loads a .fuse into its own sandboxed global table and runs Create().
-- Returns a handle for driving Process() and inspecting what came out.
function harness.load(path)
	local env = setmetatable({}, { __index = _G })

	local fuse = {
		env = env,
		registration = nil,
		printed = {},
		outputs = {},
	}

	env.CT_Tool = "CT_Tool"

	function env.FuRegisterClass(name, classtype, attrs)
		fuse.registration = { name = name, classtype = classtype, attrs = attrs }
	end

	-- Every report goes through print(), so capture it rather than letting it
	-- scroll past on stdout.
	function env.print(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[#parts + 1] = tostring((select(i, ...)))
		end
		fuse.printed[#fuse.printed + 1] = table.concat(parts, "\t")
	end

	local function newInput(name, id, attrs)
		local input = {
			Name = name,
			ID = id,
			Attrs = attrs,
			isImage = (attrs.LINKID_DataType == "Image"),
			value = attrs.INPS_DefaultText or attrs.INP_Default or 0,
			image = nil,
		}

		function input:GetValue(req)
			if self.isImage then
				return self.image
			end
			-- Fusion hands back a Parameter object; only .Value is used here.
			return { Value = self.value }
		end

		function input:SetAttrs(t)
			for k, v in pairs(t) do self.Attrs[k] = v end
		end

		return input
	end

	env.self = {
		AddInput = function(_, name, id, attrs)
			local input = newInput(name, id, attrs)
			fuse[id] = input
			return input
		end,

		AddOutput = function(_, name, id, attrs)
			local output = { Name = name, ID = id, Attrs = attrs }
			function output:Set(req, img)
				fuse.outputs[#fuse.outputs + 1] = img
			end
			return output
		end,

		GetAttrs = function(_)
			-- Named after whichever class registered itself, so reports in
			-- the test output say what they are.
			local name = fuse.registration and fuse.registration.name or "Tool"
			return { TOOLS_Name = name .. "1" }
		end,

		AddControlPage = function() end,
		BeginControlNest = function() end,
		EndControlNest = function() end,
	}

	local chunk, err = loadfile(path)
	if not chunk then
		error("failed to load " .. path .. ": " .. tostring(err), 2)
	end
	setfenv(chunk, env)
	chunk()

	env.Create()

	-- Sets a named control's value, using the input ID given to AddInput.
	function fuse:set(id, value)
		assert(self[id], "no such input: " .. tostring(id))
		self[id].value = value
	end

	-- Runs Process() against an image carrying the supplied metadata table,
	-- and returns the report text (or nil when nothing was reported).
	function fuse:process(metadata, frame)
		local img = harness.image(metadata)
		self.env.InImage.image = img

		local before = #self.printed
		local req = {
			GetTime = function() return frame or 0 end,
			IsPreCalc = function() return false end,
		}
		self.env.Process(req)

		local report = nil
		if #self.printed > before then
			report = self.printed[#self.printed]
		end
		return report, self.outputs[#self.outputs], img
	end

	-- Clicks a ButtonControl, by the input ID given to AddInput.
	function fuse:press(id)
		assert(self[id], "no such input: " .. tostring(id))
		self.env.NotifyChanged(self[id], { Value = 1 }, 0)
	end

	function fuse:reportAgain()
		self:press("ReportAgain")
	end

	return fuse
end

return harness
