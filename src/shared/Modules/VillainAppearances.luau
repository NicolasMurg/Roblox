--!strict
-- Procedural villain appearances.
--
-- "The Hollow Final" is the active villain. The Hollow / Spindle / Root /
-- Witch / Hung baselines stay in the registry as reference lineage (and
-- possible fallbacks for the eventual VillainService), but [[VillainPreview]]
-- only spawns the active villain onto the baseplate.
--
-- Each builder returns a Model whose PrimaryPart ("Root") is anchored;
-- cosmetic parts are non-anchored and welded to it via WeldConstraint, so
-- callers can move the whole rig with Model:PivotTo().

local Module = {}

export type AppearanceId = string

export type AppearanceDef = {
	Id: AppearanceId,
	DisplayName: string,
	Tagline: string,
	Build: () -> Model,
}

-- ===== Part / model helpers =====

local function newPart(name: string, size: Vector3, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function makeRootPart(): Part
	local r = Instance.new("Part")
	r.Name = "Root"
	r.Size = Vector3.new(2, 1, 1)
	r.Transparency = 1
	r.Anchored = true
	r.CanCollide = false
	r.CanQuery = false
	r.CanTouch = false
	r.Massless = true
	return r
end

local function weldTo(rootPart: BasePart, part: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = rootPart
	w.Part1 = part
	w.Parent = part
end

local function attach(
	model: Model,
	rootPart: BasePart,
	name: string,
	size: Vector3,
	color: Color3,
	offset: CFrame,
	material: Enum.Material?
): Part
	local p = newPart(name, size, color, material)
	p.CFrame = rootPart.CFrame * offset
	p.Parent = model
	weldTo(rootPart, p)
	return p
end

local function attachBall(
	model: Model,
	rootPart: BasePart,
	name: string,
	diameter: number,
	color: Color3,
	offset: CFrame,
	material: Enum.Material?
): Part
	local p = attach(model, rootPart, name, Vector3.new(diameter, diameter, diameter), color, offset, material)
	p.Shape = Enum.PartType.Ball
	return p
end

-- ===== Spindle anatomy =====

local SPINDLE_SKIN = Color3.fromRGB(10, 8, 14)
local SPINDLE_GLOW = Color3.fromRGB(220, 230, 255)

local function emptyRig(name: string): (Model, Part)
	local model = Instance.new("Model")
	model.Name = name
	local rootPart = makeRootPart()
	rootPart.Parent = model
	model.PrimaryPart = rootPart
	return model, rootPart
end

local function spindleTorso(model: Model, rootPart: BasePart, skin: Color3, material: Enum.Material?)
	attach(model, rootPart, "Torso", Vector3.new(1.1, 4, 0.7), skin, CFrame.new(0, 0.4, 0), material)
end

local function spindleHead(model: Model, rootPart: BasePart, skin: Color3, glow: Color3, material: Enum.Material?)
	attach(model, rootPart, "Neck", Vector3.new(0.3, 0.8, 0.3), skin, CFrame.new(0, 2.8, 0), material)
	attach(model, rootPart, "Head", Vector3.new(0.95, 1.1, 1), skin, CFrame.new(0, 3.6, 0), material)
	attachBall(model, rootPart, "EyeL", 0.16, glow, CFrame.new(-0.22, 3.65, -0.5), Enum.Material.Neon)
	attachBall(model, rootPart, "EyeR", 0.16, glow, CFrame.new(0.22, 3.65, -0.5), Enum.Material.Neon)
end

local function spindleArms(model: Model, rootPart: BasePart, skin: Color3, material: Enum.Material?)
	-- Split into upper arm + forearm so the possession walk animation can bend
	-- the elbow as its own joint. Total span (y=-2.6 to y=2.4) matches the
	-- single-piece original.
	attach(model, rootPart, "ArmL_Upper", Vector3.new(0.28, 2.5, 0.28), skin, CFrame.new(-0.85, 1.15, 0), material)
	attach(model, rootPart, "ArmL_Lower", Vector3.new(0.28, 2.5, 0.28), skin, CFrame.new(-0.85, -1.35, 0), material)
	attach(model, rootPart, "ArmR_Upper", Vector3.new(0.28, 2.5, 0.28), skin, CFrame.new(0.85, 1.15, 0), material)
	attach(model, rootPart, "ArmR_Lower", Vector3.new(0.28, 2.5, 0.28), skin, CFrame.new(0.85, -1.35, 0), material)
end

local function spindleLegs(model: Model, rootPart: BasePart, skin: Color3, material: Enum.Material?)
	-- Split into thigh + shin so the knee can bend during the walk cycle.
	-- Total span (y=-5.5 to y=-1.5) matches the single-piece original.
	attach(model, rootPart, "LegL_Upper", Vector3.new(0.4, 2, 0.4), skin, CFrame.new(-0.3, -2.5, 0), material)
	attach(model, rootPart, "LegL_Lower", Vector3.new(0.4, 2, 0.4), skin, CFrame.new(-0.3, -4.5, 0), material)
	attach(model, rootPart, "LegR_Upper", Vector3.new(0.4, 2, 0.4), skin, CFrame.new(0.3, -2.5, 0), material)
	attach(model, rootPart, "LegR_Lower", Vector3.new(0.4, 2, 0.4), skin, CFrame.new(0.3, -4.5, 0), material)
end

local function spindleFull(model: Model, rootPart: BasePart, skin: Color3?, glow: Color3?, material: Enum.Material?)
	local s = skin or SPINDLE_SKIN
	local g = glow or SPINDLE_GLOW
	spindleTorso(model, rootPart, s, material)
	spindleHead(model, rootPart, s, g, material)
	spindleArms(model, rootPart, s, material)
	spindleLegs(model, rootPart, s, material)
end

-- ===== Branch + lichen + trinket helpers =====

type BranchAnchor = { pos: Vector3, rot: CFrame }
type BranchOpts = {
	color: Color3,
	material: Enum.Material?,
	branchSize: Vector3?,
	twigSize: Vector3?,
	hasTwigs: boolean?,
}

local DEFAULT_ROOT_ANCHORS: { BranchAnchor } = {
	{ pos = Vector3.new(-0.6, 2.2, 0.2), rot = CFrame.Angles(math.rad(15), 0, math.rad(65)) },
	{ pos = Vector3.new(0.6, 2.2, 0.2), rot = CFrame.Angles(math.rad(15), 0, math.rad(-65)) },
	{ pos = Vector3.new(0, 2.6, 0.4), rot = CFrame.Angles(math.rad(50), 0, 0) },
	{ pos = Vector3.new(-0.45, 1.4, 0.4), rot = CFrame.Angles(math.rad(35), 0, math.rad(40)) },
	{ pos = Vector3.new(0.45, 1.4, 0.4), rot = CFrame.Angles(math.rad(35), 0, math.rad(-40)) },
	{ pos = Vector3.new(-0.3, 0.3, 0.4), rot = CFrame.Angles(math.rad(60), 0, math.rad(20)) },
	{ pos = Vector3.new(0.3, 0.3, 0.4), rot = CFrame.Angles(math.rad(60), 0, math.rad(-20)) },
}

local function addBranches(model: Model, rootPart: BasePart, anchors: { BranchAnchor }, opts: BranchOpts, prefix: string?)
	local branchSize = opts.branchSize or Vector3.new(0.18, 1.6, 0.18)
	local twigSize = opts.twigSize or Vector3.new(0.1, 0.8, 0.1)
	local tag = prefix or "Branch"
	for i, b in anchors do
		attach(model, rootPart, tag .. i, branchSize, opts.color,
			CFrame.new(b.pos) * b.rot, opts.material)
		if opts.hasTwigs ~= false then
			attach(model, rootPart, tag .. "Twig" .. i, twigSize, opts.color,
				CFrame.new(b.pos) * b.rot * CFrame.new(0.4, 0.9, 0) * CFrame.Angles(0, 0, math.rad(-25)),
				opts.material)
		end
	end
end

local function branchTipPos(anchor: BranchAnchor, branchLength: number?): Vector3
	local l = branchLength or 1.6
	return (CFrame.new(anchor.pos) * anchor.rot * CFrame.new(0.4, l + 0.4, 0)).Position
end

local function addLichen(
	model: Model,
	rootPart: BasePart,
	anchors: { BranchAnchor },
	color: Color3,
	lengthBase: number,
	count: number,
	branchLength: number?
)
	for i, anchor in anchors do
		local tipPos = branchTipPos(anchor, branchLength)
		for j = 1, count do
			local jitter = (j - (count + 1) / 2) * 0.15
			local length = lengthBase + j * 0.2
			attach(model, rootPart, "Lichen" .. i .. "_" .. j,
				Vector3.new(0.08, length, 0.08),
				color,
				CFrame.new(tipPos.X + jitter, tipPos.Y - length / 2, tipPos.Z + jitter * 0.3),
				Enum.Material.Fabric)
		end
	end
end

local function addHungTrinkets(model: Model, rootPart: BasePart, anchors: { BranchAnchor }, branchLength: number?)
	local cord = Color3.fromRGB(40, 30, 25)
	local bone = Color3.fromRGB(220, 210, 195)
	local rust = Color3.fromRGB(140, 100, 60)
	for i, anchor in anchors do
		local tip = branchTipPos(anchor, branchLength)
		local cordLen = 0.9 + (i % 3) * 0.2
		attach(model, rootPart, "Cord" .. i, Vector3.new(0.04, cordLen, 0.04), cord,
			CFrame.new(tip.X, tip.Y - cordLen / 2, tip.Z))
		local trinketY = tip.Y - cordLen - 0.2
		if i % 2 == 0 then
			attachBall(model, rootPart, "Skull" .. i, 0.42, bone,
				CFrame.new(tip.X, trinketY, tip.Z), Enum.Material.Marble)
			attachBall(model, rootPart, "SkullEyeL" .. i, 0.08, Color3.fromRGB(15, 10, 10),
				CFrame.new(tip.X - 0.1, trinketY + 0.05, tip.Z - 0.18))
			attachBall(model, rootPart, "SkullEyeR" .. i, 0.08, Color3.fromRGB(15, 10, 10),
				CFrame.new(tip.X + 0.1, trinketY + 0.05, tip.Z - 0.18))
		else
			attach(model, rootPart, "Bell" .. i, Vector3.new(0.45, 0.55, 0.45), rust,
				CFrame.new(tip.X, trinketY, tip.Z), Enum.Material.Metal)
			attach(model, rootPart, "BellLip" .. i, Vector3.new(0.55, 0.08, 0.55), rust,
				CFrame.new(tip.X, trinketY - 0.32, tip.Z), Enum.Material.Metal)
		end
	end
end

local function addStandardBranchesAndLichen(model: Model, rootPart: BasePart)
	addBranches(model, rootPart, DEFAULT_ROOT_ANCHORS, {
		color = Color3.fromRGB(45, 30, 22),
		material = Enum.Material.Wood,
	})
	addLichen(model, rootPart, DEFAULT_ROOT_ANCHORS, Color3.fromRGB(130, 140, 90), 0.9, 2)
end

-- ===== Fallback builders =====

local function buildHollow(): Model
	local model, root = emptyRig("TheHollow")
	local skin = Color3.fromRGB(14, 12, 18)
	local glow = Color3.fromRGB(220, 230, 255)
	attach(model, root, "Torso", Vector3.new(1.8, 3, 1.2), skin, CFrame.new(0, 0, 0))
	attach(model, root, "Head", Vector3.new(1.3, 1.4, 1.3), skin, CFrame.new(0, 2.2, 0))
	attachBall(model, root, "EyeL", 0.2, glow, CFrame.new(-0.3, 2.3, -0.66), Enum.Material.Neon)
	attachBall(model, root, "EyeR", 0.2, glow, CFrame.new(0.3, 2.3, -0.66), Enum.Material.Neon)
	attach(model, root, "ArmL", Vector3.new(0.4, 3.2, 0.4), skin, CFrame.new(-1.2, -0.2, 0))
	attach(model, root, "ArmR", Vector3.new(0.4, 3.2, 0.4), skin, CFrame.new(1.2, -0.2, 0))
	attach(model, root, "LegL", Vector3.new(0.55, 3, 0.55), skin, CFrame.new(-0.4, -3, 0))
	attach(model, root, "LegR", Vector3.new(0.55, 3, 0.55), skin, CFrame.new(0.4, -3, 0))
	return model
end

local function buildSpindle(): Model
	local model, root = emptyRig("TheSpindle")
	spindleFull(model, root)
	return model
end

local function buildRoot(): Model
	local model, root = emptyRig("TheRoot")
	spindleFull(model, root)
	addBranches(model, root, DEFAULT_ROOT_ANCHORS, {
		color = Color3.fromRGB(40, 28, 20),
		material = Enum.Material.Wood,
	})
	return model
end

local function buildWitch(): Model
	local model, root = emptyRig("TheWitch")
	spindleFull(model, root)
	addBranches(model, root, DEFAULT_ROOT_ANCHORS, {
		color = Color3.fromRGB(45, 30, 22),
		material = Enum.Material.Wood,
	})
	addLichen(model, root, DEFAULT_ROOT_ANCHORS, Color3.fromRGB(130, 140, 90), 1.1, 3)
	return model
end

local function buildHung(): Model
	local model, root = emptyRig("TheHung")
	spindleFull(model, root)
	addStandardBranchesAndLichen(model, root)
	addHungTrinkets(model, root, DEFAULT_ROOT_ANCHORS)
	return model
end

-- ===== Active villain: The Hollow Final =====
-- Predator-mouth fear: cranium pushed up; most of the face is an open maw
-- lined with teeth; small red predator eyes above the mouth.

local function buildHollowFinal(): Model
	local model, root = emptyRig("TheHollowFinal")
	spindleTorso(model, root, SPINDLE_SKIN)
	spindleArms(model, root, SPINDLE_SKIN)
	spindleLegs(model, root, SPINDLE_SKIN)

	attach(model, root, "Neck", Vector3.new(0.3, 0.5, 0.3), SPINDLE_SKIN, CFrame.new(0, 2.65, 0))
	attach(model, root, "Cranium", Vector3.new(0.95, 0.5, 1), SPINDLE_SKIN, CFrame.new(0, 4.2, 0))
	attachBall(model, root, "EyeL", 0.12, SPINDLE_GLOW, CFrame.new(-0.25, 4.25, -0.5), Enum.Material.Neon)
	attachBall(model, root, "EyeR", 0.12, SPINDLE_GLOW, CFrame.new(0.25, 4.25, -0.5), Enum.Material.Neon)

	-- Mouth interior: dark red, narrowed so it fits inside the cranium width.
	-- Recessed deeper than before (depth 0.2 at z=-0.1) so the cheeks/jaws sit
	-- in front of it from any viewing angle.
	attach(model, root, "MawBack", Vector3.new(0.95, 1.0, 0.2), Color3.fromRGB(110, 18, 22),
		CFrame.new(0, 3.3375, -0.1), Enum.Material.SmoothPlastic)
	-- Cheeks: black side panels filling the gap between the jaw edge and the
	-- cranium edge at mouth height. Without these, the MawBack's left/right
	-- faces were visible from profile views as red strips.
	attach(model, root, "CheekL", Vector3.new(0.075, 1.0, 0.8), SPINDLE_SKIN,
		CFrame.new(-0.5125, 3.3375, -0.25))
	attach(model, root, "CheekR", Vector3.new(0.075, 1.0, 0.8), SPINDLE_SKIN,
		CFrame.new(0.5125, 3.3375, -0.25))
	-- Back panel: blocks the back face of the MawBack from being seen behind
	-- the head (the cranium doesn't reach down to the mouth's vertical band).
	attach(model, root, "BackOfHead", Vector3.new(0.95, 1.075, 0.05), SPINDLE_SKIN,
		CFrame.new(0, 3.4125, 0.05))
	-- Jaw slabs: same color/material as the body (SPINDLE_SKIN) so the mouth
	-- frame blends into the head from the outside.
	attach(model, root, "UpperJaw", Vector3.new(1.1, 0.2, 0.8), SPINDLE_SKIN, CFrame.new(0, 3.9, -0.25))
	attach(model, root, "LowerJaw", Vector3.new(1.1, 0.35, 0.8), SPINDLE_SKIN, CFrame.new(0, 2.7, -0.25))

	-- Teeth: thinner pillars, slightly longer than before. X range tightened
	-- so all six teeth fit fully inside the (narrower) MawBack and don't poke
	-- into the cheeks.
	local tooth = SPINDLE_GLOW
	for i = 0, 5 do
		local x = -0.4 + i * 0.16
		attach(model, root, "ToothU" .. i, Vector3.new(0.08, 0.4, 0.08), tooth,
			CFrame.new(x, 3.65, -0.45), Enum.Material.Neon)
		attach(model, root, "ToothL" .. i, Vector3.new(0.08, 0.4, 0.08), tooth,
			CFrame.new(x, 2.95, -0.45), Enum.Material.Neon)
	end

	addStandardBranchesAndLichen(model, root)
	addHungTrinkets(model, root, DEFAULT_ROOT_ANCHORS)
	return model
end

-- ===== Registry =====

local function def(id: AppearanceId, displayName: string, tagline: string, build: () -> Model): AppearanceDef
	return { Id = id, DisplayName = displayName, Tagline = tagline, Build = build }
end

local Registry: { [AppearanceId]: AppearanceDef } = {
	the_hollow = def("the_hollow", "The Hollow", "Tall. Faceless. Always one room behind you.", buildHollow),
	the_hollow_spindle = def("the_hollow_spindle", "The Spindle", "Folds itself through doorways.", buildSpindle),
	the_spindle_root = def("the_spindle_root", "The Root", "It hasn't moved in years. The forest grew through it.", buildRoot),
	the_root_witch = def("the_root_witch", "The Witch", "Dressed in cobwebs and grandmother's hair.", buildWitch),
	the_witch_hung = def("the_witch_hung", "The Hung", "Bells and bones. You hear her coming.", buildHung),
	the_hollow_final = def("the_hollow_final", "The Hollow Final", "Most of her head is the mouth.", buildHollowFinal),
}

-- ID of the active villain — the one [[VillainPreview]] should spawn.
-- Lineage models above stay available via Get/Build for future use but are not
-- placed in the world by the preview script.
Module.ActiveVillainId = "the_hollow_final" :: AppearanceId

-- ===== Public API =====

function Module.Get(id: AppearanceId): AppearanceDef?
	return Registry[id]
end

function Module.All(): { [AppearanceId]: AppearanceDef }
	return Registry
end

function Module.Ids(): { AppearanceId }
	local ids = {}
	for id in Registry do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

function Module.Build(id: AppearanceId, parent: Instance?): Model?
	local entry = Registry[id]
	if not entry then
		return nil
	end
	local model = entry.Build()
	if parent then
		model.Parent = parent
	end
	return model
end

return Module
