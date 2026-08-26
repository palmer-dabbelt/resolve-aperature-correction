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

	-- Fuses ask the image for its region rather than its nominal size.
	img.DataWindow = {
		Width = function() return 1920 end,
		Height = function() return 1080 end,
	}

	function img:CopyOf()
		local copy = harness.image(self.Metadata)
		copy.copiedFrom = self
		return copy
	end

	function img:Gain(r, g, b, a)
		self.gains[#self.gains + 1] = { r = r, g = g, b = b, a = a }
	end

	-- Returns a new image, as the real one does, recording the operation so a
	-- test can assert on the correction that was applied.
	function img:ChannelOpOf(operation, fg, options)
		local result = harness.image(self.Metadata)
		result.copiedFrom = self
		result.channelOp = { operation = operation, fg = fg, options = options }
		return result
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
		out = {},
		outputAttrs = {},

		-- Whether the stubbed GPU is present, and whether its kernels run.
		-- Both default on; a test flips them to exercise the fallbacks.
		gpuAvailable = true,
		gpuRuns = true,
	}

	env.CT_Tool = "CT_Tool"

	-- DCTL sampler modes. The fuse only passes these straight through, so
	-- their values matter no more than that they are distinguishable.
	env.TEX_FILTER_MODE_POINT = "point"
	env.TEX_FILTER_MODE_LINEAR = "linear"
	env.TEX_ADDRESS_MODE_CLAMP = "clamp"
	env.TEX_ADDRESS_MODE_BORDER = "border"
	env.TEX_NORMALIZED_COORDS_FALSE = false
	env.TEX_NORMALIZED_COORDS_TRUE = true

	-- Fusion wraps plain numbers in a Parameter before they travel down a
	-- link; only .Value is ever read back, so that is all this carries.
	function env.Number(v)
		return { Value = v }
	end

	function env.Image(attrs)
		local like = attrs and attrs.IMG_Like
		local img = harness.image(like and like.Metadata or nil)
		img.createdFrom = like
		return img
	end

	-- A stand-in GPU compute node. It doesn't run a kernel, it records what it
	-- was asked to run so a test can check the parameters that reached it.
	function env.DVIPComputeNode(req, kernelName, kernelSource, paramsName, paramsBlock)
		if not fuse.gpuAvailable then return nil end

		local node = {
			kernel = kernelName,
			source = kernelSource,
			inputs = {},
			outputs = {},
			params = {},
		}

		function node:GetParamBlock()
			return { srcsize = {} }
		end

		function node:SetParamBlock(params)
			self.params = params
		end

		function node:AddSampler(name, filterMode, addressMode, normCoords)
			self.sampler = { name = name, filter = filterMode, address = addressMode, norm = normCoords }
		end

		function node:AddInput(name, image)
			self.inputs[name] = image
		end

		function node:AddOutput(name, image)
			self.outputs[name] = image
		end

		function node:RunSession(request)
			if not fuse.gpuRuns then return false end
			for _, image in pairs(self.outputs) do
				image.gpu = {
					kernel = self.kernel,
					gain = self.params.gain,
					sampler = self.sampler,
					inputs = self.inputs,
				}
			end
			return true
		end

		fuse.lastNode = node
		return node
	end

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
			fuse.outputAttrs[id] = attrs
			function output:Set(req, value)
				fuse.outputs[#fuse.outputs + 1] = value
				-- Also by ID, because a tool with more than one output makes
				-- "the last thing set" an unhelpful way to ask for one.
				fuse.out[self.ID] = value
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
		return report, self.out.Output, img
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
