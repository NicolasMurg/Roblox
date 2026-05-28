--!strict
-- MapService: clones map templates from ServerStorage.Maps into Workspace
-- for a match, and cleans up on match end. One map instance per match.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

local MapService = Knit.CreateService({
	Name = "MapService",

	_activeMap = nil :: Model?,
})

function MapService:LoadMap(mapName: string): Model?
	if self._activeMap then
		self._activeMap:Destroy()
		self._activeMap = nil
	end

	local template = ServerStorage.Maps:FindFirstChild(mapName)
	if not template then
		warn("[MapService] no map named:", mapName)
		return nil
	end

	local instance = template:Clone() :: Model
	instance.Parent = workspace
	self._activeMap = instance
	return instance
end

function MapService:UnloadMap()
	if self._activeMap then
		self._activeMap:Destroy()
		self._activeMap = nil
	end
end

function MapService:GetSpawnPoints(): { BasePart }
	local spawns = {}
	if not self._activeMap then
		return spawns
	end
	for _, desc in self._activeMap:GetDescendants() do
		if desc:IsA("BasePart") and desc.Name == "PlayerSpawn" then
			table.insert(spawns, desc)
		end
	end
	return spawns
end

function MapService:KnitStart() end

return MapService
