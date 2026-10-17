--!nocheck
-- Executes PlayerDataCore's real Set implementation with mocked Roblox services.
-- This uses no live DataStoreService and tests both Value.Changed and direct-queue fields.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")
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

local instance_methods = {}

function instance_methods:IsA(class_name)
	return self.ClassName == class_name
end

function instance_methods:FindFirstChild(name)
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
	return self._attributes[name]
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
	local storage_key = name .. "|" .. scope .. "|" .. key
	local record = {
		Key = key,
		State = "new",
		_options = options,
		_storage_key = storage_key,
	}

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

local NumberFormatter = luau.load(fs.readFile("src/PlayerDataInitializer/NumberFormatter.luau"), {
	debugName = "NumberFormatter",
})()
local IntegerInfinityValue = luau.load(fs.readFile("src/PlayerDataInitializer/IntegerInfinityValue.luau"), {
	debugName = "IntegerInfinityValue",
	environment = { Instance = Instance },
})()
local CodeNumValue = {
	is_value = function(value) return type(value) == "string" end,
	normalize = function(value) return tostring(value) end,
	is_serialized = function(value) return type(value) == "string" end,
	format = function(value) return tostring(value) end,
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
	NumberFormatter = {},
	CodeNumValue = {},
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
local module_require_counts = { CodeNumValue = 0 }

local function mock_require(target)
	if target == module_tokens.RecordStore then return RecordStore end
	if target == module_tokens.IntegerInfinityValue then return IntegerInfinityValue end
	if target == module_tokens.NumberFormatter then return NumberFormatter end
	if target == module_tokens.CodeNumValue then
		module_require_counts.CodeNumValue += 1
		return CodeNumValue
	end
	error("unexpected dependency passed to require")
end
local function mock_typeof(value)
	if type(value) == "table" and rawget(value, "__mock_instance") == true then
		return "Instance"
	end
	return builtin_typeof(value)
end

local PlayerDataCore = luau.load(fs.readFile("src/PlayerDataInitializer/PlayerDataCore.luau"), {
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
	module_require_counts.CodeNumValue == 0,
	"PlayerDataCore eagerly required optional CodeNumValue in the default configuration"
)

local controller = PlayerDataCore.new({
	Players = Players,
	RecordStore = RecordStore,
	IntegerInfinityValue = IntegerInfinityValue,
	NumberFormatter = NumberFormatter,
	CodeNumValue = CodeNumValue,
	new_instance = function(class_name) return Instance.new(class_name) end,
	task = task,
})

assert(
	module_require_counts.CodeNumValue == 0,
	"default PlayerData controller should not load CodeNumValue when the field is unused"
)
assert(controller:Start(), "controller failed to start")
local deadline = os.clock() + 5
while player:GetAttribute("PlayerDataLoadStatus") ~= "Loaded" and os.clock() < deadline do
	task.wait(0.01)
end
assert(player:GetAttribute("PlayerDataLoadStatus") == "Loaded", "player session did not load")

local success, message = controller.Set(player, "kills", 12500124)
assert(success, message)
success, message = controller.Set(player, "equipped", "Hi")
assert(success, message)
success, message = controller.Set(player, "admin", true)
assert(success, message)
assert(not controller.Set(player, "admin", "true"), "invalid boolean value was accepted")
assert(not controller.Set(player, "not_a_field", 1), "unknown field was accepted")

local values = player:FindFirstChild("PlayerDataValues")
local leaderstats = player:FindFirstChild("leaderstats")
assert(values ~= nil and leaderstats ~= nil, "runtime folders are missing")
local kills = values:FindFirstChild("kills")
local kills_display = leaderstats:FindFirstChild("Kills")
local equipped_display = leaderstats:FindFirstChild("Equipped")
assert(kills ~= nil and kills.Value == 12500124, "kills backing value did not update")
assert(equipped_display ~= nil and equipped_display.Value == "Hi", "Equipped did not update")
assert(kills_display ~= nil and kills_display.Value == "12.5M", "formatted Kills display did not refresh")

task.wait(0.1)
assert(controller:Shutdown(), "controller failed to shut down")
local stored = saved_records["PlayerData_Test1|global|Player_" .. tostring(player.UserId)]
assert(stored ~= nil, "mock record was not saved")
assert(stored.kills == 12500124, "kills was not persisted")
assert(stored.equipped == "Hi", "equipped was not persisted")
assert(stored.admin == true, "non-leaderstat admin value was not persisted")

print("[PlayerData.Set] Lune integration regression passed")
