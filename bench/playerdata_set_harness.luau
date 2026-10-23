--!nocheck
-- Shared mock PlayerDataCore harness for regression and CodSpeed path benchmarks.
return function(use_cached_paths)

local function replace_source_once(source, old_text, new_text)
	local start_index, end_index = string.find(source, old_text, 1, true)
	assert(start_index ~= nil, "expected source text was not found")
	local duplicate_index = string.find(source, old_text, end_index + 1, true)
	assert(duplicate_index == nil, "source replacement text was not unique")
	return string.sub(source, 1, start_index - 1)
		.. new_text
		.. string.sub(source, end_index + 1)
end

local function replace_source_range(source, start_marker, end_marker, replacement)
	local start_index = string.find(source, start_marker, 1, true)
	assert(start_index ~= nil, "source range start was not found")
	local end_index = string.find(source, end_marker, start_index + #start_marker, true)
	assert(end_index ~= nil, "source range end was not found")
	return string.sub(source, 1, start_index - 1)
		.. replacement
		.. string.sub(source, end_index)
end

	-- Executes PlayerDataCore's real Set implementation with mocked Roblox services.
	-- This uses no live DataStoreService and tests both Value.Changed and direct-queue fields.
	
	local fs = require("@lune/fs")
	local luau = require("@lune/luau")
	local task = require("@lune/task")
	local InfiniteMath = require("./infinimath_shim").load_infinitemath()
	local builtin_typeof = typeof
	
	local function make_signal()
		local handlers = {}
		local signal = {}
	
		function signal:Connect(callback)
			local connection = { Connected = true }
			function connection:Disconnect()
				self.Connected = false
			end
			table.insert(handlers, { callback = callback, connection = connection })
			return connection
		end
	
		function signal:Fire(...)
			local args = table.pack(...)
			for _, handler in ipairs(handlers) do
				if handler.connection.Connected then
					handler.callback(table.unpack(args, 1, args.n))
				end
			end
		end
	
		return signal
	end
	
	local find_first_child_calls = 0
	local instance_methods = {}
	
	function instance_methods:IsA(class_name)
		return self.ClassName == class_name
	end
	
	function instance_methods:FindFirstChild(name)
		find_first_child_calls += 1
		for _, child in ipairs(self._children) do
			if child.Name == name and not child._destroyed then
				return child
			end
		end
		return nil
	end
	
	function instance_methods:SetAttribute(name, value)
		self._attributes[name] = value
	end
	
	function instance_methods:GetAttribute(name)

	function instance_methods:Kick(message)
		self._kick_message = message
	end
		return self._attributes[name]
	end

	function instance_methods:GetPropertyChangedSignal(property_name)
		if property_name == "Value" then
			return self._signals.Changed
		end
		error("unsupported property-change signal: " .. tostring(property_name), 2)
	end
	
	function instance_methods:Destroy()
		if self._destroyed then
			return
		end
		self.Destroying:Fire()
		local children = table.clone(self._children)
		for _, child in ipairs(children) do
			child:Destroy()
		end
		self.Parent = nil
		self._destroyed = true
	end
	
	local function set_parent(instance, parent)
		local old_parent = rawget(instance, "_parent")
		if old_parent == parent then
			return
		end
		if type(old_parent) == "table" and type(old_parent._children) == "table" then
			for index = #old_parent._children, 1, -1 do
				if old_parent._children[index] == instance then
					table.remove(old_parent._children, index)
				end
			end
		end
		rawset(instance, "_parent", parent)
		if type(parent) == "table" and type(parent._children) == "table" then
			table.insert(parent._children, instance)
		end
	end
	
	local Instance = {}
	
	function Instance.new(class_name)
		local initial_value = nil
		if class_name == "StringValue" then
			initial_value = ""
		elseif class_name == "BoolValue" then
			initial_value = false
		elseif class_name == "NumberValue" or class_name == "IntValue" then
			initial_value = 0
		end
	
		local object = {
			__mock_instance = true,
			ClassName = class_name,
			Name = "",
			_children = {},
			_attributes = {},
			_signals = {
				Changed = make_signal(),
				Destroying = make_signal(),
			},
			_value = initial_value,
			_parent = nil,
			_destroyed = false,
		}
		return setmetatable(object, {
			__index = function(self, key)
				if key == "Parent" then
					return rawget(self, "_parent")
				elseif key == "Value" then
					return rawget(self, "_value")
				elseif key == "Changed" then
					return rawget(self, "_signals").Changed
				elseif key == "Destroying" then
					return rawget(self, "_signals").Destroying
				end
				return instance_methods[key] or rawget(self, key)
			end,
			__newindex = function(self, key, value)
				if key == "Parent" then
					set_parent(self, value)
				elseif key == "Value" then
					local old_value = rawget(self, "_value")
					rawset(self, "_value", value)
					if old_value ~= value then
						rawget(self, "_signals").Changed:Fire(value)
					end
				else
					rawset(self, key, value)
				end
			end,
		})
	end
	
	local Players = {
		_children = {},
		_players = {},
		PlayerAdded = make_signal(),
		PlayerRemoving = make_signal(),
	}
	function Players:GetPlayers()
		return table.clone(self._players)
	end
	
	local player = Instance.new("Player")
	player.Name = "SetApiRegression"
	player.UserId = 4306219285
	player.Parent = Players
	table.insert(Players._players, player)
	
	local saved_records = {}
	local captured_record_options = nil
	local captured_record = nil
	local function clone_data(data)
		local result = {}
		for key, value in pairs(data) do
			result[key] = value
		end
		return result
	end
	
	local RecordStore = {}
	function RecordStore.is_retryable_result()
		return false
	end
	function RecordStore.get_diagnostic_code()
		return "TEST"
	end
	function RecordStore.new(name, scope, key, options)
		captured_record_options = options
		local storage_key = name .. "|" .. scope .. "|" .. key
		local record = {
			Key = key,
			State = "new",
			_options = options,
			_storage_key = storage_key,
		}
		captured_record = record
	
		function record:Open(template)
			if saved_records[self._storage_key] == nil then
				saved_records[self._storage_key] = clone_data(template)
				self.State = "active"
				return "created", nil
			end
			self.State = "active"
			return "loaded", nil
		end
	
		function record:IsOpen()
			return self.State == "active"
		end
	
		function record:Get()
			return clone_data(saved_records[self._storage_key])
		end
	
		function record:Update(transform)
			if self.State ~= "active" then
				return "fenced", "record is not active"
			end
			local candidate = transform(clone_data(saved_records[self._storage_key]))
			if type(candidate) ~= "table" then
				return "validation", "update returned no data"
			end
			if self._options.validator ~= nil then
				local valid, message = self._options.validator(candidate)
				if not valid then
					return "validation", message
				end
			end
			saved_records[self._storage_key] = clone_data(candidate)
			return "success", nil
		end
	
		function record:Stats()
			return { busy = 0 }
		end
	
		function record:Close()
			self.State = "closed"
			return "closed", nil
		end
	
		function record:GetState()
			return self.State
		end
	
		function record:GetLastError()
			return nil
		end
	
		return record
	end
	
	local IntegerInfinityValue = luau.load(fs.readFile("src/PlayerDataInitializer/IntegerInfinityValue.luau"), {
		debugName = "IntegerInfinityValue",
		environment = { Instance = Instance },
	})()
	local native_number_format_calls = 0
	local InfiniteMathFormatter = {
		format = function(value, options)
			native_number_format_calls += 1
			return InfiniteMath.format(value, options)
		end,
	}

	local InfiniteMathValue = {
		is_value = function(value) return type(value) == "string" end,
		normalize = function(value) return tostring(value) end,
		is_serialized = function(value) return type(value) == "string" end,
		format = function(value, _options)
			if type(value) == "number" then
				error("native-number formatting must not use the InfiniteMathValue persistence adapter", 2)
			end
			return tostring(value)
		end,
		new = function(name, value)
			local backing = Instance.new("StringValue")
			backing.Name = name
			backing.Value = tostring(value)
			return backing
		end,
	}
	
	local module_tokens = {
		RecordStore = {},
		IntegerInfinityValue = {},
		InfiniteMathValue = {},
	}
	local module_script = {
		Parent = module_tokens,
	}
	local services = { Players = Players }
	local game = {
		GetService = function(_self, name)
			assert(services[name] ~= nil, "unexpected service request: " .. tostring(name))
			return services[name]
		end,
	}
	local module_require_counts = { InfiniteMathValue = 0 }
	
	local function mock_require(target)
		if target == module_tokens.RecordStore then return RecordStore end
		if target == module_tokens.IntegerInfinityValue then return IntegerInfinityValue end
		if target == module_tokens.InfiniteMathValue then
			module_require_counts.InfiniteMathValue += 1
			return InfiniteMathValue
		end
		error("unexpected dependency passed to require")
	end
	local function mock_typeof(value)
		if type(value) == "table" and rawget(value, "__mock_instance") == true then
			return "Instance"
		end
		return builtin_typeof(value)
	end
	
	local player_data_core_source = fs.readFile("src/PlayerDataInitializer/PlayerDataCore.luau")
	if not use_cached_paths then
		player_data_core_source = replace_source_range(
			player_data_core_source,
			"\n\t\tlocal values_by_key: { [string]: Instance } = {}",
			"\n\tend\n\n\tlocal function find_cached_player_child(",
			""
		)
		player_data_core_source = replace_source_range(
			player_data_core_source,
			"\tlocal function find_cached_player_child(",
			"\tlocal function normalize_set_value(",
			"\tlocal function find_player_value_instance(player: Player, key: string, field: DataField): Instance?\n\t\tif not CONFIG.leaderstats.enabled then\n\t\t\treturn nil\n\t\tend\n\n\t\tlocal definition = leaderstat_by_key[key]\n\t\tif field.class_name == \"InfiniteMathValue\"\n\t\t\tor (definition ~= nil and definition.number_format ~= nil)\n\t\tthen\n\t\t\tlocal values = player:FindFirstChild(\"PlayerDataValues\")\n\t\t\treturn if values ~= nil then values:FindFirstChild(key) else nil\n\t\tend\n\n\t\tif definition ~= nil then\n\t\t\tlocal leaderstats = player:FindFirstChild(CONFIG.leaderstats.name)\n\t\t\treturn if leaderstats ~= nil then leaderstats:FindFirstChild(definition.name) else nil\n\t\tend\n\n\t\treturn nil\n\tend\n\n"
		)
		player_data_core_source = replace_source_once(
			player_data_core_source,
			"\tlocal player_value_paths: { [Player]: PlayerValuePathCache } = setmetatable({}, { __mode = \"k\" })\n",
			""
		)
		player_data_core_source = replace_source_once(
			player_data_core_source,
			"\t\tplayer_value_paths[player] = nil\n",
			""
		)
	end

	local PlayerDataCore = luau.load(player_data_core_source, {
		debugName = "PlayerDataCore",
		environment = {
			game = game,
			script = module_script,
			require = mock_require,
			Instance = Instance,
			task = task,
			typeof = mock_typeof,
		},
	})()
	assert(
		module_require_counts.InfiniteMathValue == 0,
		"PlayerDataCore eagerly required optional InfiniteMathValue in the default configuration"
	)
	
	local controller = PlayerDataCore.new({
		Players = Players,
		RecordStore = RecordStore,
		IntegerInfinityValue = IntegerInfinityValue,
		InfiniteMathValue = InfiniteMathValue,
		InfiniteMathFormatter = InfiniteMathFormatter,
		new_instance = function(class_name) return Instance.new(class_name) end,
		task = task,
	})
	
	assert(
		module_require_counts.InfiniteMathValue == 0,
		"default PlayerData controller should not load InfiniteMathValue when the field is unused"
	)
	assert(controller:Start(), "controller failed to start")
	local deadline = os.clock() + 5
	while player:GetAttribute("PlayerDataLoadStatus") ~= "Loaded"
		and player:GetAttribute("PlayerDataLoadStatus") ~= "Failed"
		and os.clock() < deadline do
		task.wait(0.01)
	end
		task.wait(0.01)
	end
	assert(
		player:GetAttribute("PlayerDataLoadStatus") == "Loaded",
		("player session did not load (status=%s, kick=%s)"):format(
			tostring(player:GetAttribute("PlayerDataLoadStatus")),
			tostring(player._kick_message)
		)
	)
	assert(native_number_format_calls > 0, "default Kills display did not use InfiniteMathFormatter")
	assert(module_require_counts.InfiniteMathValue == 0,
		"default native leaderstats should not load the InfiniteMathValue adapter")
	return {
		controller = controller,
		player = player,
		players = Players,
		record = captured_record,
		saved_records = saved_records,
		get_record_options = function()
			return captured_record_options
		end,
		task = task,
		get_find_first_child_calls = function()
			return find_first_child_calls
		end,
	}
end
