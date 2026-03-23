-- TrailerPlateSync.lua
-- Core sync module for FS25_TrueRegPlate.
--
-- Source references:
--   LicensePlates.lua        : setLicensePlatesData (l.171), getLicensePlatesData (l.200),
--                              getHasLicensePlates (l.224), onReadStream (l.162),
--                              onWriteStream (l.167), saveToXMLFile (l.153),
--                              onPostLoad (l.128), onDelete (l.149),
--                              initSpecialization (l.5)
--   LicensePlate.lua         : updateData (l.152), setColorIndex (l.230)
--   LicensePlateManager.lua  : readLicensePlateData (l.211), writeLicensePlateData (l.229)
--   Attachable.lua           : postAttach (l.1241), postDetach (l.1314),
--                              spec.attacherVehicle nil before onPostDetach (l.1348)

TrueRegPlate = TrueRegPlate or {}

local LOG = "[TRP]"

-- ---------------------------------------------------------------------------
-- TrueRegPlate.applyPlateDataVisuals
-- Visual-only update — never touches spec.licensePlateData.
-- Mirrors LicensePlates:setLicensePlatesData lines 174-198.
-- ---------------------------------------------------------------------------
function TrueRegPlate.applyPlateDataVisuals(vehicle, plateData)
    if plateData == nil
    or plateData.variation     == nil
    or plateData.characters    == nil
    or plateData.colorIndex    == nil
    or plateData.placementIndex == nil then
        return
    end

    local spec = vehicle.spec_licensePlates

    for i = 1, #spec.licensePlates do
        local licensePlate = spec.licensePlates[i]

        local allowLicensePlate = true
        if plateData.placementIndex == LicensePlateManager.PLACEMENT_OPTION.NONE then
            allowLicensePlate = false
        elseif plateData.placementIndex == LicensePlateManager.PLACEMENT_OPTION.BACK_ONLY then
            if licensePlate.position == LicensePlateManager.PLATE_POSITION.FRONT then
                allowLicensePlate = false
            end
        end

        if allowLicensePlate then
            licensePlate.data:updateData(
                plateData.variation,
                licensePlate.position,
                table.concat(plateData.characters, ""),
                true
            )
            licensePlate.data:setColorIndex(plateData.colorIndex)
            setVisibility(licensePlate.data.node, true)
        else
            setVisibility(licensePlate.data.node, false)
        end

        ObjectChangeUtil.setObjectChanges(
            licensePlate.changeObjects,
            allowLicensePlate,
            vehicle,
            vehicle.setMovingToolDirty
        )
    end
end

-- ---------------------------------------------------------------------------
-- Schema registration — tpsManuallyPlaced persistence
-- Appended to LicensePlates.initSpecialization (LicensePlates.lua l.5)
-- ---------------------------------------------------------------------------
LicensePlates.initSpecialization = Utils.appendedFunction(
    LicensePlates.initSpecialization,
    function()
        Logging.info("%s initSpecialization: registering tpsManuallyPlaced XML path", LOG)
        local schemaSavegame = Vehicle.xmlSchemaSavegame
        schemaSavegame:register(
            XMLValueType.BOOL,
            "vehicles.vehicle(?).licensePlates#tpsManuallyPlaced",
            "TrueRegPlate: plate was manually placed by player",
            false
        )
    end
)

-- ---------------------------------------------------------------------------
-- saveToXMLFile wrapper
-- Source: LicensePlates.lua l.153
-- ---------------------------------------------------------------------------
LicensePlates.saveToXMLFile = Utils.appendedFunction(
    LicensePlates.saveToXMLFile,
    function(self, xmlFile, key, usedModNames)
        local spec = self.spec_licensePlates
        if spec ~= nil and spec.tpsManuallyPlaced then
            Logging.info("%s saveToXMLFile: writing tpsManuallyPlaced=true for %s",
                LOG, key)
            xmlFile:setValue(key .. "#tpsManuallyPlaced", true)
        end
    end
)

-- ---------------------------------------------------------------------------
-- onPostLoad wrapper
-- Source: LicensePlates.lua l.128
-- ---------------------------------------------------------------------------
LicensePlates.onPostLoad = Utils.appendedFunction(
    LicensePlates.onPostLoad,
    function(self, savegame)
        local spec = self.spec_licensePlates
        if spec == nil then return end
        spec.tpsManuallyPlaced = false
        spec.tpsOverride = nil
        if savegame ~= nil then
            spec.tpsManuallyPlaced = savegame.xmlFile:getValue(
                savegame.key .. ".licensePlates#tpsManuallyPlaced",
                false
            )
            Logging.info("%s onPostLoad: vehicle=%s tpsManuallyPlaced=%s",
                LOG,
                savegame.key,
                tostring(spec.tpsManuallyPlaced))
        end
    end
)

-- ---------------------------------------------------------------------------
-- onDelete wrapper
-- Source: LicensePlates.lua l.149
-- ---------------------------------------------------------------------------
LicensePlates.onDelete = Utils.appendedFunction(
    LicensePlates.onDelete,
    function(self)
        Logging.info("%s onDelete: vehicle with plates deleted — notifying PlateHandover", LOG)
        if PlateHandover ~= nil then
            PlateHandover.onVehicleWithPlatesDeleted(self)
        end
    end
)

-- ---------------------------------------------------------------------------
-- onPostAttachAppended
-- Source: Attachable.lua l.1241
-- ---------------------------------------------------------------------------
local function onPostAttachAppended(self, attacherVehicle, inputJointDescIndex,
                                     jointDescIndex, loadFromSavegame)
    if self.getHasLicensePlates == nil or not self:getHasLicensePlates() then
        return
    end
    local rootVehicle = self.rootVehicle
    if rootVehicle == nil or rootVehicle == self then
        return
    end
    if rootVehicle.getHasLicensePlates == nil
    or not rootVehicle:getHasLicensePlates() then
        Logging.info("%s onPostAttach: trailer has plates but rootVehicle does not — skip", LOG)
        return
    end

    Logging.info("%s onPostAttach: trailer attached | loadFromSavegame=%s",
        LOG, tostring(loadFromSavegame))

    if PlateHandover ~= nil then
        PlateHandover.onTrailerAttached(self, rootVehicle, loadFromSavegame)
    end

    if loadFromSavegame then
        local spec = self.spec_licensePlates
        if spec.tpsManuallyPlaced and spec.licensePlateData ~= nil then
            Logging.info("%s onPostAttach (savegame): manually placed plate found — setting tpsOverride", LOG)
            spec.tpsOverride = spec.licensePlateData
        elseif not spec.tpsManuallyPlaced then
            local rootPlateData = rootVehicle:getLicensePlatesData()
            if rootPlateData ~= nil then
                Logging.info("%s onPostAttach (savegame): no manual plate — applying tractor plate for display continuity", LOG)
                TrueRegPlate.applyPlateDataVisuals(self, rootPlateData)
                spec.tpsOverride = rootPlateData
            else
                Logging.info("%s onPostAttach (savegame): no manual plate and tractor has no plate data", LOG)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- onPostDetachAppended
-- Source: Attachable.lua l.1314 — spec.attacherVehicle already nil (l.1348)
-- ---------------------------------------------------------------------------
local function onPostDetachAppended(self, implementIndex)
    if self.getHasLicensePlates == nil or not self:getHasLicensePlates() then
        return
    end

    local spec = self.spec_licensePlates

    Logging.info("%s onPostDetach: trailer detached | tpsManuallyPlaced=%s",
        LOG, tostring(spec.tpsManuallyPlaced))

    if PlateHandover ~= nil then
        PlateHandover.onTrailerDetached(self)
    end

    if not spec.tpsManuallyPlaced then
        Logging.info("%s onPostDetach: no manual plate — clearing override and restoring own plate", LOG)
        spec.tpsOverride = nil
        self:setLicensePlatesData(self:getLicensePlatesData())
    else
        Logging.info("%s onPostDetach: manual plate present — plate stays on trailer", LOG)
    end
end

-- ---------------------------------------------------------------------------
-- onWriteStreamAppended — server only
-- Source: LicensePlateManager.writeLicensePlateData (l.229)
-- ---------------------------------------------------------------------------
local function onWriteStreamAppended(self, streamId, connection)
    local spec = self.spec_licensePlates
    local hasOverride = spec.tpsOverride ~= nil

    streamWriteBool(streamId, hasOverride)
    if hasOverride then
        Logging.info("%s onWriteStream: sending override plate '%s' to client",
            LOG, tostring(spec.tpsOverride.characters and table.concat(spec.tpsOverride.characters, "") or "?"))
        LicensePlateManager.writeLicensePlateData(streamId, connection, spec.tpsOverride)
    else
        Logging.info("%s onWriteStream: no override — sending hasOverride=false", LOG)
    end
end

-- ---------------------------------------------------------------------------
-- onReadStreamAppended — client only
-- Source: LicensePlateManager.readLicensePlateData (l.211)
-- ---------------------------------------------------------------------------
local function onReadStreamAppended(self, streamId, connection)
    local hasOverride = streamReadBool(streamId)

    if hasOverride then
        local overrideData = LicensePlateManager.readLicensePlateData(streamId, connection)
        Logging.info("%s onReadStream: received override plate '%s' — applying visuals",
            LOG, tostring(overrideData.characters and table.concat(overrideData.characters, "") or "?"))
        TrueRegPlate.applyPlateDataVisuals(self, overrideData)
        self.spec_licensePlates.tpsOverride = overrideData
    else
        Logging.info("%s onReadStream: no override received", LOG)
        self.spec_licensePlates.tpsOverride = nil
    end
end

-- ---------------------------------------------------------------------------
-- Register all hooks
-- ---------------------------------------------------------------------------
Logging.info("%s TrailerPlateSync.lua loaded — registering hooks", LOG)

Attachable.postAttach = Utils.appendedFunction(Attachable.postAttach, onPostAttachAppended)
Attachable.postDetach = Utils.appendedFunction(Attachable.postDetach, onPostDetachAppended)

LicensePlates.onWriteStream = Utils.appendedFunction(LicensePlates.onWriteStream, onWriteStreamAppended)
LicensePlates.onReadStream  = Utils.appendedFunction(LicensePlates.onReadStream,  onReadStreamAppended)

Logging.info("%s All hooks registered", LOG)
