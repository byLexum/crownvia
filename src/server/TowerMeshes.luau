--!strict
-- Model kalıpları: MeshId betikten atanamadığı için MeshPart'lar sunucuda
-- `AssetService:CreateMeshPartAsync` ile bir kez kurulur ve ReplicatedStorage altına konur;
-- istemci kopyalar. Kuleler `TowerMeshes` (WorldView), menzilli mermiler `ProjectileMeshes` ve
-- yoldaki birlikler `UnitMeshes` (ForceView). Kalıp gelmezse istemci ilkel parçalarla çizer.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Art = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Art")
local ProjectileArt = require(Art:WaitForChild("ProjectileArt"))
local PropArt = require(Art:WaitForChild("PropArt"))
local TowerArt = require(Art:WaitForChild("TowerArt"))
local UnitArt = require(Art:WaitForChild("UnitArt"))

local TowerMeshes = {}

-- Taban genişliği (stud). Kuleler arası 15 stud (WorldView.STUDS_PER_UNIT × 5).
local FOOTPRINT = 6

local function build(
	name: string,
	mesh: number,
	texture: number,
	size: (Vector3) -> Vector3
): MeshPart
	local part = AssetService:CreateMeshPartAsync(Content.fromAssetId(mesh))
	part.Name = name
	part.TextureID = "rbxassetid://" .. texture
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.Size = size(part.Size)
	return part
end

local function buildAll(folderName: string, jobs: { [string]: () -> MeshPart })
	local folder = Instance.new("Folder")
	folder.Name = folderName
	folder.Parent = ReplicatedStorage
	for name, job in jobs do
		task.spawn(function()
			local ok, result = pcall(job)
			if ok then
				result.Parent = folder
			else
				warn("[TowerMeshes] " .. name .. ": " .. tostring(result))
			end
		end)
	end
end

function TowerMeshes.start()
	local towers: { [string]: () -> MeshPart } = {}
	for name, art in TowerArt do
		towers[name] = function()
			return build(name, art.mesh, art.texture, function(size)
				return size * (FOOTPRINT / math.max(size.X, size.Z))
			end)
		end
	end
	buildAll("TowerMeshes", towers)

	local projectiles: { [string]: () -> MeshPart } = {}
	for name, art in ProjectileArt.meshes do
		projectiles[name] = function()
			local part = build(name, art.mesh, art.texture, function(size)
				return size * (art.length / size.X)
			end)
			part.CastShadow = false
			part.CanQuery = false
			return part
		end
	end
	buildAll("ProjectileMeshes", projectiles)

	local units: { [string]: () -> MeshPart } = {}
	for name, art in UnitArt.meshes do
		units[name] = function()
			local part = build(name, art.mesh, art.texture, function(size)
				return size * (art.length / math.max(size.X, size.Z))
			end)
			part.CanQuery = false
			return part
		end
	end
	buildAll("UnitMeshes", units)

	local props: { [string]: () -> MeshPart } = {}
	for name, art in PropArt.meshes do
		props[name] = function()
			local part = build(name, art.mesh, art.texture, function(size)
				return size * (art.height / size.Y)
			end)
			part.CanQuery = false
			return part
		end
	end
	buildAll("PropMeshes", props)
end

return TowerMeshes
