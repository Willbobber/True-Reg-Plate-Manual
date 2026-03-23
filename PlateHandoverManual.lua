-- PlateHandover.lua
-- Walk-up-and-place mechanic for FS25_TrueRegPlate.
--
-- Flow:
--   1. Trailer is attached to tractor (by any means — cab Q or Manual Attach)
--   2. Player exits cab, walks to the REAR OF THE TRACTOR
--      → Prompt: "Take plate (DA24 HYT)"  [InputAction.ACTIVATE_OBJECT]
--   3. Player walks to the REAR OF THE TRAILER
--      → Prompt: "Attach plate (DA24 HYT)"  or  "Replace plate (OLD → NEW)"
--   4. Plate writes permanently into spec.licensePlateData on the trailer
--   5. If trailer already has a manually placed plate and no plate in hand:
--      → Prompt: "Remove plate (DA24 HYT)"
--
-- Source references:
--   ActivatableObjectsSystem.lua : addActivatable/removeActivatable, interface
--                                   (activateText, getIsActivatable, getDistance,
--                                    run, update), InputAction.ACTIVATE_OBJECT
--   HandTool.lua                 : thirdPersonRightHandNode access pattern (l.747)
--   LicensePlateManager.lua      : getLicensePlate (l.170), PLATE_TYPE, PLATE_POSITION
--   LicensePlate.lua             : clone (l.106), updateData (l.152),
--                                   setColorIndex (l.230), delete (l.103)
--   LicensePlates.lua            : setLicensePlatesData (l.171), getLicensePlatesData (l.200),
--                                   getHasLicensePlates (l.224)
--   Attachable.lua               : spec_attachable.attacherVehicle confirmed (l.1194)
--   AttacherJoints.lua / Attachable.lua : attachedImplements, implement.jointDescIndex,
--                                          attacherJoints[i].jointTransform (l.527, l.1278)
--   HandTool.lua l.747           : thirdPersonRightHandNode on playerModel

PlateHandover = {}

-- Interaction radius in metres. Both getIsActivatable AND getDistance gate on this.
-- getIsActivatable must gate on distance too — ActivatableObjectsSystem:updateObjects
-- (l.81) sets nearestObject when nearestObject==nil regardless of distance value,
-- so out-of-range activatables still fire if they are the only ones passing
-- getIsActivatable.
PlateHandover.INTERACTION_DISTANCE = 1.5

-- ---- Global carry state (local player only, runtime only, never saved) ----
PlateHandover.carriedPlate       = nil   -- plateData table or nil
PlateHandover.carriedPlateVisual = nil   -- LicensePlate clone or nil

-- Maps (keyed by vehicle reference for O(1) lookup and removal)
PlateHandover.tractorActivatables = {}   -- tractor  → PlatePickupActivatable
PlateHandover.trailerActivatables = {}   -- trailer  → PlateAttachActivatable
PlateHandover.trailerToTractor    = {}   -- trailer  → tractor  (for detach cleanup)

-- ---------------------------------------------------------------------------
-- Prompt strings (hardcoded English — add l10n file later if needed)
-- ---------------------------------------------------------------------------
local FMT_TAKE    = "Take plate (%s)"
local FMT_ATTACH  = "Attach plate (%s)"
local FMT_REPLACE = "Replace plate (%s \226\134\146 %s)"   -- → is U+2192
local FMT_REMOVE  = "Remove plate (%s)"
local TEXT_TAKE_BLANK   = "Take plate"
local TEXT_ATTACH_BLANK = "Attach plate"
local TEXT_REMOVE_BLANK = "Remove plate"

-- Log prefix — grep for [TRP] in log.txt to see all mod output
local LOG = "[TRP]"

-- ---------------------------------------------------------------------------
-- Helper: compact reg string from characters table
-- ---------------------------------------------------------------------------
local function regString(plateData)
    if plateData ~= nil and plateData.characters ~= nil then
        return table.concat(plateData.characters, "")
    end
    return ""
end

-- Helper: short vehicle name for log readability
local function vname(vehicle)
    if vehicle == nil then return "nil" end
    if vehicle.configFileName ~= nil then
        return Utils.getFilenameInfo(vehicle.configFileName, true) or "unknown"
    end
    return tostring(vehicle)
end

-- ===========================================================================
-- PlatePickupActivatable
-- Registered at the tractor's rear attacher joint node.
-- Visible when:
--   - Player is on foot (no current vehicle)
--   - Player is not already carrying a plate
--   - Tractor has valid plate data
--   - Trailer is still physically attached to this tractor
--   - Player is within INTERACTION_DISTANCE of the attacher joint node
-- ===========================================================================
local PlatePickupActivatable = {}
PlatePickupActivatable.__index = PlatePickupActivatable

function PlatePickupActivatable.new(tractor, trailer)
    local self = setmetatable({}, PlatePickupActivatable)
    self.tractor = tractor
    self.trailer = trailer
    self.activateText = TEXT_TAKE_BLANK   -- non-nil required by addActivatable
    self:_refreshText()
    Logging.info("%s PlatePickupActivatable created | tractor=%s trailer=%s",
        LOG, vname(tractor), vname(trailer))
    return self
end

function PlatePickupActivatable:_refreshText()
    local reg = regString(self.tractor:getLicensePlatesData())
    if reg ~= "" then
        self.activateText = string.format(FMT_TAKE, reg)
    else
        self.activateText = TEXT_TAKE_BLANK
    end
end

-- Called every tick by ActivatableObjectsSystem when this is nearest — not logged.
function PlatePickupActivatable:update(dt)
    self:_refreshText()
end

function PlatePickupActivatable:getIsActivatable()
    if g_localPlayer == nil then return false end
    if g_localPlayer:getCurrentVehicle() ~= nil then return false end
    if PlateHandover.carriedPlate ~= nil then return false end
    if not self.tractor:getHasLicensePlates() then return false end
    if self.tractor:getLicensePlatesData() == nil then return false end
    -- _getJointNode nil means trailer is no longer attached — abort.
    -- Source: AttacherJoints.lua spec.attachedImplements, implement.jointDescIndex
    if self:_getJointNode() == nil then return false end
    local px, _, pz = getWorldTranslation(g_localPlayer.rootNode)
    return self:_getInteractionDist2D(px, pz) <= PlateHandover.INTERACTION_DISTANCE
end

function PlatePickupActivatable:getDistance(x, y, z)
    local dist = self:_getInteractionDist2D(x, z)
    if dist > PlateHandover.INTERACTION_DISTANCE then return math.huge end
    return dist
end

-- Returns the minimum 2D horizontal distance to the player from either the
-- tractor's rear plate node or the attacher joint node — whichever is closer.
--
-- Neither node alone covers all vehicles:
--   HGV 5th-wheel (Volvo FH16): jointTransform sits under the trailer deck,
--   player can only reach the rear cab plate node on the bumper.
--   Roof-plate tractors (JCB Fastrac): the plate node X/Z is above the cab
--   roof and forward of the rear hitch, so the joint node at the 3PH is
--   the reachable point.
-- Taking the minimum means the prompt fires when the player is within range
-- of whichever node they can physically stand next to.
--
-- Source: LicensePlates.lua l.248-250 (plate node),
--         AttacherJoints.lua spec.attachedImplements (joint node)
function PlatePickupActivatable:_getInteractionDist2D(px, pz)
    local best = math.huge
    local plateNode = self:_getTractorPlateNode()
    if plateNode ~= nil then
        local nx, _, nz = getWorldTranslation(plateNode)
        best = math.min(best, MathUtil.vector2Length(px - nx, pz - nz))
    end
    local jointNode = self:_getJointNode()
    if jointNode ~= nil then
        local jx, _, jz = getWorldTranslation(jointNode)
        best = math.min(best, MathUtil.vector2Length(px - jx, pz - jz))
    end
    return best
end

-- Tractor's BACK plate node (cab exterior).
-- Source: LicensePlates.lua l.248-250
function PlatePickupActivatable:_getTractorPlateNode()
    local spec = self.tractor.spec_licensePlates
    for i = 1, #spec.licensePlates do
        local lp = spec.licensePlates[i]
        if lp.position == LicensePlateManager.PLATE_POSITION.BACK then
            return lp.node
        end
    end
    if #spec.licensePlates > 0 then
        return spec.licensePlates[#spec.licensePlates].node
    end
    return nil
end

-- Attacher joint node — used for attachment verification AND as one of the
-- two distance candidates. Returns nil when trailer is not attached.
-- Source: AttacherJoints.lua spec.attachedImplements, implement.jointDescIndex
function PlatePickupActivatable:_getJointNode()
    local spec = self.tractor.spec_attacherJoints
    if spec == nil then return nil end
    for _, implement in ipairs(spec.attachedImplements) do
        if implement.object == self.trailer then
            local jointDesc = spec.attacherJoints[implement.jointDescIndex]
            if jointDesc ~= nil then
                return jointDesc.jointTransform
            end
        end
    end
    return nil
end

-- Player pressed ACTIVATE_OBJECT at tractor rear — take the plate.
function PlatePickupActivatable:run()
    local plateData = self.tractor:getLicensePlatesData()
    if plateData == nil then
        Logging.info("%s PlatePickup.run: ABORTED — tractor %s has no plateData",
            LOG, vname(self.tractor))
        return
    end

    -- Deep copy so carry state is independent of tractor spec
    local copy = {
        variation      = plateData.variation,
        colorIndex     = plateData.colorIndex,
        placementIndex = plateData.placementIndex,
        characters     = {}
    }
    for i, c in ipairs(plateData.characters) do
        copy.characters[i] = c
    end

    PlateHandover.carriedPlate = copy
    Logging.info("%s PlatePickup.run: player took plate '%s' from tractor %s",
        LOG, regString(copy), vname(self.tractor))

    PlateHandover.createCarriedPlateVisual(copy)
end

-- ===========================================================================
-- PlateAttachActivatable
-- Registered at the trailer's rear plate node.
-- ===========================================================================
local PlateAttachActivatable = {}
PlateAttachActivatable.__index = PlateAttachActivatable

function PlateAttachActivatable.new(trailer)
    local self = setmetatable({}, PlateAttachActivatable)
    self.trailer = trailer
    self.activateText = TEXT_ATTACH_BLANK   -- non-nil required by addActivatable
    self:_refreshText()
    Logging.info("%s PlateAttachActivatable created | trailer=%s", LOG, vname(trailer))
    return self
end

function PlateAttachActivatable:_refreshText()
    local spec = self.trailer.spec_licensePlates
    local newReg = regString(PlateHandover.carriedPlate)

    if PlateHandover.carriedPlate ~= nil then
        if spec.tpsManuallyPlaced and spec.licensePlateData ~= nil then
            local oldReg = regString(spec.licensePlateData)
            self.activateText = string.format(FMT_REPLACE, oldReg, newReg)
        else
            self.activateText = string.format(FMT_ATTACH, newReg)
        end
    elseif spec.tpsManuallyPlaced then
        local reg = regString(spec.licensePlateData)
        if reg ~= "" then
            self.activateText = string.format(FMT_REMOVE, reg)
        else
            self.activateText = TEXT_REMOVE_BLANK
        end
    else
        self.activateText = TEXT_ATTACH_BLANK
    end
end

-- Called every tick when nearest — not logged.
function PlateAttachActivatable:update(dt)
    self:_refreshText()
end

-- NOTE: no logging here — called every tick.
function PlateAttachActivatable:getIsActivatable()
    if g_localPlayer == nil then return false end
    if g_localPlayer:getCurrentVehicle() ~= nil then return false end
    local spec = self.trailer.spec_licensePlates
    -- 2D horizontal distance — same reasoning as PlatePickupActivatable.
    -- Semi-trailer plate nodes can be elevated; using X/Z only ensures
    -- the player just needs to be horizontally close regardless of height.
    local node = self:_getPlateNode()
    if node == nil then return false end
    local px, _, pz = getWorldTranslation(g_localPlayer.rootNode)
    local nx, _, nz = getWorldTranslation(node)
    if MathUtil.vector2Length(px - nx, pz - nz) > PlateHandover.INTERACTION_DISTANCE then
        return false
    end
    if PlateHandover.carriedPlate ~= nil then return true end
    if spec.tpsManuallyPlaced then return true end
    return false
end

function PlateAttachActivatable:getDistance(x, y, z)
    local node = self:_getPlateNode()
    if node == nil then return math.huge end
    local nx, _, nz = getWorldTranslation(node)
    -- 2D horizontal distance matches getIsActivatable
    local dist = MathUtil.vector2Length(x - nx, z - nz)
    if dist > PlateHandover.INTERACTION_DISTANCE then return math.huge end
    return dist
end

-- Finds the rear (BACK) plate node, falls back to last plate node.
-- Source: LicensePlates.lua l.248-250
function PlateAttachActivatable:_getPlateNode()
    local spec = self.trailer.spec_licensePlates
    for i = 1, #spec.licensePlates do
        local lp = spec.licensePlates[i]
        if lp.position == LicensePlateManager.PLATE_POSITION.BACK then
            return lp.node
        end
    end
    if #spec.licensePlates > 0 then
        return spec.licensePlates[#spec.licensePlates].node
    end
    return nil
end

-- Player pressed ACTIVATE_OBJECT at trailer rear.
function PlateAttachActivatable:run()
    local trailer = self.trailer
    local spec    = trailer.spec_licensePlates

    if PlateHandover.carriedPlate ~= nil then
        -- ---- Attach or Replace ----
        local plateData = PlateHandover.carriedPlate
        local newReg    = regString(plateData)
        local oldReg    = spec.tpsManuallyPlaced and regString(spec.licensePlateData) or "none"

        Logging.info("%s PlateAttach.run: ATTACH trailer=%s old='%s' new='%s'",
            LOG, vname(trailer), oldReg, newReg)

        -- Write permanently into spec.licensePlateData
        -- Source: LicensePlates:setLicensePlatesData l.171 writes spec.licensePlateData l.193
        trailer:setLicensePlatesData(plateData)

        spec.tpsManuallyPlaced = true
        spec.tpsOverride       = plateData   -- MP: stream to late joiners

        PlateHandover.clearCarriedPlate()

    else
        -- ---- Remove ----
        local reg = regString(spec.licensePlateData)
        Logging.info("%s PlateAttach.run: REMOVE plate '%s' from trailer=%s",
            LOG, reg, vname(trailer))

        spec.tpsManuallyPlaced = false
        spec.tpsOverride       = nil
        spec.licensePlateData  = nil
        -- nil → hides all plate nodes — Source: LicensePlates.lua l.196-198
        trailer:setLicensePlatesData(nil)
    end

    self:_refreshText()
end

-- ===========================================================================
-- Module lifecycle
-- ===========================================================================

function PlateHandover.onTrailerAttached(trailer, tractor, loadFromSavegame)
    Logging.info("%s onTrailerAttached: trailer=%s tractor=%s loadFromSavegame=%s",
        LOG, vname(trailer), vname(tractor), tostring(loadFromSavegame))

    if g_currentMission == nil or g_currentMission.activatableObjectsSystem == nil then
        Logging.info("%s onTrailerAttached: ABORT — activatableObjectsSystem not ready", LOG)
        return
    end
    if not trailer:getHasLicensePlates() then
        Logging.info("%s onTrailerAttached: ABORT — trailer has no license plate nodes", LOG)
        return
    end
    if not tractor:getHasLicensePlates() then
        Logging.info("%s onTrailerAttached: ABORT — tractor has no license plate nodes", LOG)
        return
    end

    PlateHandover.trailerToTractor[trailer] = tractor

    -- Remove stale pickup activatable if tractor was previously used with another trailer
    local oldPickup = PlateHandover.tractorActivatables[tractor]
    if oldPickup ~= nil then
        Logging.info("%s onTrailerAttached: removing stale pickup activatable for tractor=%s",
            LOG, vname(tractor))
        g_currentMission.activatableObjectsSystem:removeActivatable(oldPickup)
    end

    local pickupActivatable = PlatePickupActivatable.new(tractor, trailer)
    PlateHandover.tractorActivatables[tractor] = pickupActivatable
    g_currentMission.activatableObjectsSystem:addActivatable(pickupActivatable)
    Logging.info("%s onTrailerAttached: pickup activatable REGISTERED for tractor=%s", LOG, vname(tractor))

    if PlateHandover.trailerActivatables[trailer] == nil then
        local attachActivatable = PlateAttachActivatable.new(trailer)
        PlateHandover.trailerActivatables[trailer] = attachActivatable
        g_currentMission.activatableObjectsSystem:addActivatable(attachActivatable)
        Logging.info("%s onTrailerAttached: attach activatable REGISTERED for trailer=%s", LOG, vname(trailer))
    else
        Logging.info("%s onTrailerAttached: attach activatable already exists for trailer=%s (reuse)", LOG, vname(trailer))
    end
end

function PlateHandover.onTrailerDetached(trailer)
    Logging.info("%s onTrailerDetached: trailer=%s", LOG, vname(trailer))

    if g_currentMission == nil or g_currentMission.activatableObjectsSystem == nil then
        Logging.info("%s onTrailerDetached: ABORT — activatableObjectsSystem not ready", LOG)
        return
    end

    local tractor = PlateHandover.trailerToTractor[trailer]
    if tractor ~= nil then
        local pickupActivatable = PlateHandover.tractorActivatables[tractor]
        if pickupActivatable ~= nil then
            g_currentMission.activatableObjectsSystem:removeActivatable(pickupActivatable)
            PlateHandover.tractorActivatables[tractor] = nil
            Logging.info("%s onTrailerDetached: pickup activatable REMOVED for tractor=%s", LOG, vname(tractor))
        else
            Logging.info("%s onTrailerDetached: no pickup activatable found for tractor=%s", LOG, vname(tractor))
        end
        PlateHandover.trailerToTractor[trailer] = nil
    else
        Logging.info("%s onTrailerDetached: no tractor association found for trailer=%s", LOG, vname(trailer))
    end

    if PlateHandover.carriedPlate ~= nil then
        Logging.info("%s onTrailerDetached: carry in progress — cancelling", LOG)
        PlateHandover.clearCarriedPlate()
    end
end

function PlateHandover.onVehicleWithPlatesDeleted(vehicle)
    Logging.info("%s onVehicleWithPlatesDeleted: vehicle=%s", LOG, vname(vehicle))

    if g_currentMission == nil or g_currentMission.activatableObjectsSystem == nil then
        return
    end

    local attachActivatable = PlateHandover.trailerActivatables[vehicle]
    if attachActivatable ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(attachActivatable)
        PlateHandover.trailerActivatables[vehicle] = nil
        Logging.info("%s onVehicleWithPlatesDeleted: attach activatable removed", LOG)
    end

    local pickupActivatable = PlateHandover.tractorActivatables[vehicle]
    if pickupActivatable ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(pickupActivatable)
        PlateHandover.tractorActivatables[vehicle] = nil
        Logging.info("%s onVehicleWithPlatesDeleted: pickup activatable removed", LOG)
    end

    PlateHandover.trailerToTractor[vehicle] = nil

    for trailer, tractor in pairs(PlateHandover.trailerToTractor) do
        if tractor == vehicle then
            PlateHandover.trailerToTractor[trailer] = nil
            Logging.info("%s onVehicleWithPlatesDeleted: removed trailerToTractor entry for trailer=%s",
                LOG, vname(trailer))
        end
    end

    if PlateHandover.carriedPlate ~= nil then
        Logging.info("%s onVehicleWithPlatesDeleted: carry in progress — cancelling", LOG)
        PlateHandover.clearCarriedPlate()
    end
end

-- ===========================================================================
-- Carry state helpers
-- ===========================================================================

-- Creates a visible clone of the map plate geometry and links it to the
-- player's right hand node.
-- Source: LicensePlateManager:getLicensePlate l.170 calls clone() internally.
-- Hand node: HandTool.lua l.747 thirdPersonRightHandNode.
function PlateHandover.createCarriedPlateVisual(plateData)
    if not g_licensePlateManager:getAreLicensePlatesAvailable() then
        Logging.info("%s createCarriedPlateVisual: SKIP — license plates not available", LOG)
        return
    end

    local plate = g_licensePlateManager:getLicensePlate(
        LicensePlateManager.PLATE_TYPE.ELONGATED,
        false
    )
    if plate == nil then
        Logging.info("%s createCarriedPlateVisual: SKIP — getLicensePlate returned nil", LOG)
        return
    end

    plate:updateData(
        plateData.variation,
        LicensePlateManager.PLATE_POSITION.ANY,
        table.concat(plateData.characters, ""),
        true
    )
    plate:setColorIndex(plateData.colorIndex)
    setVisibility(plate.node, true)

    local linked = false
    if g_localPlayer ~= nil
    and g_localPlayer.graphicsComponent ~= nil
    and g_localPlayer.graphicsComponent.model ~= nil then
        local handNode = g_localPlayer.graphicsComponent.model.thirdPersonRightHandNode
        if handNode ~= nil then
            link(handNode, plate.node)
            setTranslation(plate.node, 0, 0.04, 0.08)
            setRotation(plate.node,    0, 0,    0)
            linked = true
            Logging.info("%s createCarriedPlateVisual: plate '%s' linked to right hand node",
                LOG, regString(plateData))
        else
            Logging.info("%s createCarriedPlateVisual: thirdPersonRightHandNode is nil — using fallback", LOG)
        end
    else
        Logging.info("%s createCarriedPlateVisual: graphicsComponent or model is nil — using fallback", LOG)
    end

    if not linked then
        link(getRootNode(), plate.node)
        setVisibility(plate.node, false)
        Logging.info("%s createCarriedPlateVisual: fallback — plate parked at world root (invisible)", LOG)
    end

    PlateHandover.carriedPlateVisual = plate
end

-- Clears carry state and deletes the visual clone.
-- LicensePlate:delete() confirmed LicensePlate.lua l.103
function PlateHandover.clearCarriedPlate()
    Logging.info("%s clearCarriedPlate: clearing carry state", LOG)
    PlateHandover.carriedPlate = nil
    if PlateHandover.carriedPlateVisual ~= nil then
        unlink(PlateHandover.carriedPlateVisual.node)
        PlateHandover.carriedPlateVisual:delete()
        PlateHandover.carriedPlateVisual = nil
        Logging.info("%s clearCarriedPlate: visual deleted", LOG)
    end
end
