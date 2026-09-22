ConstructionProgressDisplay = {}

ConstructionProgressDisplay.MOD_NAME = g_currentModName
ConstructionProgressDisplay.SPEC_NAME = string.format("%s.constructionProgressDisplay", g_currentModName)
ConstructionProgressDisplay.SPEC = string.format("spec_%s", ConstructionProgressDisplay.SPEC_NAME)

local CPD = ConstructionProgressDisplay
local SPEC_KEY = CPD.SPEC
local LOG_PREFIX = "[ConstructionProgressDisplay:Stage10-OPT-MP-FIX1]"

CPD.activeRenderStands = {}
-- All stand instances, including dedicated-server instances. Used only for
-- authoritative lifecycle bookkeeping; rendering remains client-only.
CPD.trackedStands = {}
CPD.palletCapacityCache = {}


local MAX_VISIBLE_STAGES = 9
local MAX_VISIBLE_MATERIALS = 13
local DEFAULT_REPORT_REFRESH_INTERVAL_MS = 5000
local FALLBACK_STORAGE_SNAPSHOT_INTERVAL_MS = 1000
local MP_TARGET_RESOLVE_INTERVAL_MS = 500
local DETAILED_REPORT_LOGGING = false

-- Forward declaration is required: initSpecialization is defined much earlier
-- than the finalize-hook implementation. Without this declaration Lua resolves
-- the name in initSpecialization as a global and the hook call becomes nil.
local installConstructibleFinalizeHook

local function logInfo(fmt, ...)
    Logging.info(LOG_PREFIX .. " " .. fmt, ...)
end

local function getPlaceableUniqueId(placeable)
    if placeable ~= nil and placeable.getUniqueId ~= nil then
        return placeable:getUniqueId()
    end
    return nil
end

local function getPlaceableName(placeable)
    if placeable ~= nil and placeable.getName ~= nil then
        return placeable:getName()
    end
    return "<unnamed>"
end

local function isCompatibleConstructible(placeable)
    return placeable ~= nil
        and placeable.spec_constructible ~= nil
        and placeable.spec_constructible.stateMachine ~= nil
        and not placeable.isDeleted
        and not placeable.markedForDeletion
end

local function getConstructibleEffectiveStateIndex(placeable)
    local constructible = placeable ~= nil and placeable.spec_constructible or nil
    if constructible == nil then
        return nil
    end

    return constructible.stateIndex
        or constructible.stateIndexPending
        or constructible.startStateIndex
end

local function isActiveConstructible(placeable)
    if not isCompatibleConstructible(placeable) then
        return false
    end

    local constructible = placeable.spec_constructible
    local stateIndex = getConstructibleEffectiveStateIndex(placeable)
    local state = stateIndex ~= nil and constructible.stateMachine[stateIndex] or nil

    return state ~= nil
        and ConstructibleStateBuilding ~= nil
        and state.isa ~= nil
        and state:isa(ConstructibleStateBuilding)
end

local function getHorizontalDistanceSqToStand(self, placeable)
    if placeable == nil or placeable.getPosition == nil then
        return nil
    end

    local searchX, _, searchZ = self:getConstructionProgressDisplaySearchPosition()
    local targetX, _, targetZ = placeable:getPosition()
    local dx = targetX - searchX
    local dz = targetZ - searchZ
    return dx * dx + dz * dz
end

local function isWithinSearchRadius(self, placeable)
    local spec = self[SPEC_KEY]
    if spec == nil then
        return false, nil
    end

    local distanceSq = getHorizontalDistanceSqToStand(self, placeable)
    if distanceSq == nil then
        return false, nil
    end

    local radius = spec.searchRadius or 30
    return distanceSq <= radius * radius, distanceSq
end

local function sortTargetRegistry(spec)
    table.sort(spec.targets, function(a, b)
        if a.distanceSq ~= b.distanceSq then
            return a.distanceSq < b.distanceSq
        end
        return tostring(a.uniqueId) < tostring(b.uniqueId)
    end)
end

local function scanNearbyConstructibles(self, activeOnly)
    local results = {}
    local spec = self[SPEC_KEY]

    if spec == nil
        or g_currentMission == nil
        or g_currentMission.placeableSystem == nil
        or g_currentMission.placeableSystem.placeables == nil then
        return results
    end

    local radius = spec.searchRadius or 30
    local radiusSq = radius * radius

    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        if isCompatibleConstructible(placeable)
            and (not activeOnly or isActiveConstructible(placeable)) then
            local distanceSq = getHorizontalDistanceSqToStand(self, placeable)
            if distanceSq ~= nil and distanceSq <= radiusSq then
                table.insert(results, {
                    placeable = placeable,
                    uniqueId = getPlaceableUniqueId(placeable),
                    distanceSq = distanceSq
                })
            end
        end
    end

    table.sort(results, function(a, b)
        if a.distanceSq ~= b.distanceSq then
            return a.distanceSq < b.distanceSq
        end
        return tostring(a.uniqueId) < tostring(b.uniqueId)
    end)

    return results
end

function CPD.prerequisitesPresent(specializations)
    return true
end

function CPD.initSpecialization()
    installConstructibleFinalizeHook()

    -- Tab selection is deliberately local, transient UI state.
    -- It is not stored in savegames and not synchronized between players.
end

function CPD.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(
        placeableType,
        "getConstructionProgressDisplaySearchPosition",
        CPD.getConstructionProgressDisplaySearchPosition
    )
    SpecializationUtil.registerFunction(
        placeableType,
        "getConstructionProgressDisplayTargets",
        CPD.getConstructionProgressDisplayTargets
    )
    SpecializationUtil.registerFunction(
        placeableType,
        "getConstructionProgressDisplayTargetCount",
        CPD.getConstructionProgressDisplayTargetCount
    )
    SpecializationUtil.registerFunction(
        placeableType,
        "subscribeConstructionProgressDisplayLifecycle",
        CPD.subscribeConstructionProgressDisplayLifecycle
    )
    SpecializationUtil.registerFunction(
        placeableType,
        "initializeConstructionProgressDisplayRegistry",
        CPD.initializeConstructionProgressDisplayRegistry
    )
    SpecializationUtil.registerFunction(
        placeableType,
        "addConstructionProgressDisplayTarget",
        CPD.addConstructionProgressDisplayTarget
    )
    SpecializationUtil.registerFunction(
        placeableType,
        "removeConstructionProgressDisplayTarget",
        CPD.removeConstructionProgressDisplayTarget
    )
    SpecializationUtil.registerFunction(
        placeableType,
        "setConstructionProgressDisplaySelectedTarget",
        CPD.setConstructionProgressDisplaySelectedTarget
    )
end

function CPD.registerOverwrittenFunctions(placeableType)
    -- ConstructionBrushPlaceable:verifyPlacement() calls getCanBePlacedAt()
    -- before the stock ownership / restricted-zone / overlap checks. Returning
    -- false here gives this stand its own localized placement denial while
    -- leaving every later stock validation intact.
    SpecializationUtil.registerOverwrittenFunction(
        placeableType,
        "getCanBePlacedAt",
        CPD.getCanBePlacedAt
    )

    -- Stage 3 board-only farmland ownership exception.
    SpecializationUtil.registerOverwrittenFunction(
        placeableType,
        "getIsOnOwnedFarmland",
        CPD.getIsOnOwnedFarmland
    )
end

function CPD.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", CPD)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", CPD)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream", CPD)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", CPD)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", CPD)
end

function CPD.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("ConstructionProgressDisplay")

    schema:register(
        XMLValueType.NODE_INDEX,
        basePath .. ".constructionProgressDisplay#searchNode",
        "Origin used for nearby construction searches"
    )
    schema:register(
        XMLValueType.FLOAT,
        basePath .. ".constructionProgressDisplay#searchRadius",
        "Maximum horizontal distance to a compatible PlaceableConstructible",
        30
    )
    schema:register(
        XMLValueType.INT,
        basePath .. ".constructionProgressDisplay#refreshIntervalMs",
        "Construction report data refresh interval in milliseconds",
        DEFAULT_REPORT_REFRESH_INTERVAL_MS
    )
    schema:register(
        XMLValueType.NODE_INDEX,
        basePath .. ".constructionProgressDisplay#paperNode",
        "Root node of the paper surface"
    )
    schema:register(
        XMLValueType.NODE_INDEX,
        basePath .. ".constructionProgressDisplay#contentNode",
        "Anchor node for world-space renderText3D content"
    )
    schema:register(
        XMLValueType.NODE_INDEX,
        basePath .. ".constructionProgressDisplay#progressBarsNode",
        "Root node for the two physical progress bars"
    )
    schema:register(
        XMLValueType.NODE_INDEX,
        basePath .. ".constructionProgressDisplay#reportFormNode",
        "Root node for physical report-form lines"
    )
    schema:register(
        XMLValueType.NODE_INDEX,
        basePath .. ".constructionProgressDisplay#photoNode",
        "Shape used for the selected construction site's store image"
    )
    schema:register(
        XMLValueType.NODE_INDEX,
        basePath .. ".constructionProgressDisplay#stageBarsNode",
        "Root node for visible construction-stage bars"
    )
    schema:register(
        XMLValueType.NODE_INDEX,
        basePath .. ".constructionProgressDisplay#materialBarsNode",
        "Root node for visible material progress bars"
    )
    schema:register(
        XMLValueType.NODE_INDEX,
        basePath .. ".constructionProgressDisplay#overallProgressFillNode",
        "Fill mesh for overall construction progress"
    )
    schema:register(
        XMLValueType.NODE_INDEX,
        basePath .. ".constructionProgressDisplay#interactionNode",
        "Reference node for future player interaction"
    )
    schema:register(
        XMLValueType.NODE_INDEX,
        basePath .. ".constructionProgressDisplay#tabsNode",
        "Root node for physical document tabs"
    )

    schema:setXMLSpecializationType()
end


function CPD.registerSavegameXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("ConstructionProgressDisplay")

    schema:register(XMLValueType.STRING, basePath .. ".targets.target(?)#uniqueId", "Tracked construction placeable unique id")
    schema:register(XMLValueType.STRING, basePath .. ".targets.target(?).finalStorage.material(?)#fillType", "Final stored material fill type")
    schema:register(XMLValueType.FLOAT, basePath .. ".targets.target(?).finalStorage.material(?)#level", "Final stored material level")

    -- Migration support for 0.10.1.0/0.10.1.1 duplicated specialization node.
    schema:register(XMLValueType.STRING, basePath .. ".constructionProgressDisplay.targets.target(?)#uniqueId", "Legacy tracked construction unique id")
    schema:register(XMLValueType.STRING, basePath .. ".constructionProgressDisplay.targets.target(?).finalStorage.material(?)#fillType", "Legacy final stored material fill type")
    schema:register(XMLValueType.FLOAT, basePath .. ".constructionProgressDisplay.targets.target(?).finalStorage.material(?)#level", "Legacy final stored material level")

    schema:setXMLSpecializationType()
end


function CPD:onLoad(savegame)
    if installConstructibleFinalizeHook ~= nil then
        installConstructibleFinalizeHook()
    end

    local spec = self[SPEC_KEY]
    if spec == nil then
        Logging.error("%s specialization table '%s' is missing", LOG_PREFIX, SPEC_KEY)
        return
    end

    local key = "placeable.constructionProgressDisplay"
    spec.searchNode = self.xmlFile:getValue(
        key .. "#searchNode",
        self.rootNode,
        self.components,
        self.i3dMappings
    )
    spec.searchRadius = math.max(
        self.xmlFile:getValue(key .. "#searchRadius", 30),
        0
    )
    spec.paperNode = self.xmlFile:getValue(
        key .. "#paperNode",
        nil,
        self.components,
        self.i3dMappings
    )
    spec.contentNode = self.xmlFile:getValue(
        key .. "#contentNode",
        nil,
        self.components,
        self.i3dMappings
    )
    spec.progressBarsNode = self.xmlFile:getValue(
        key .. "#progressBarsNode",
        nil,
        self.components,
        self.i3dMappings
    )
    spec.reportFormNode = self.xmlFile:getValue(
        key .. "#reportFormNode",
        nil,
        self.components,
        self.i3dMappings
    )
    spec.photoNode = self.xmlFile:getValue(
        key .. "#photoNode",
        nil,
        self.components,
        self.i3dMappings
    )
    spec.photoMaterial = nil
    spec.photoCurrentFilename = nil
    spec.photoHasImage = false
    spec.photoPlaceholderFilename = Utils.getFilename(
        "placeables/constructionProgressDisplay/textures/photo_placeholder.dds",
        g_currentModDirectory
    )
    if spec.photoNode ~= nil and spec.photoNode ~= 0 and getNumOfMaterials(spec.photoNode) > 0 then
        spec.photoMaterial = getMaterial(spec.photoNode, 0)
    end
    spec.stageBarsNode = self.xmlFile:getValue(
        key .. "#stageBarsNode",
        nil,
        self.components,
        self.i3dMappings
    )
    spec.materialBarsNode = self.xmlFile:getValue(
        key .. "#materialBarsNode",
        nil,
        self.components,
        self.i3dMappings
    )
    spec.overallProgressFillNode = self.xmlFile:getValue(
        key .. "#overallProgressFillNode",
        nil,
        self.components,
        self.i3dMappings
    )
    if spec.progressBarsNode ~= nil and spec.progressBarsNode ~= 0 then
        setVisibility(spec.progressBarsNode, false)
    end
    if spec.reportFormNode ~= nil and spec.reportFormNode ~= 0 then
        setVisibility(spec.reportFormNode, false)
    end
    spec.reportRefreshIntervalMs = math.max(1000, self.xmlFile:getValue(
        key .. "#refreshIntervalMs",
        DEFAULT_REPORT_REFRESH_INTERVAL_MS
    ))
    spec.reportRefreshTimerMs = 0
    spec.reportDirty = true
    spec.reportForceRefresh = true
    spec.reportData = nil
    spec.selectedTargetUniqueId = nil
    spec.stagePageStart = nil
    spec.materialPageStart = 1
    spec.lastReportLogSignature = nil
    -- Stage 10 keeps the Stage 09 lifecycle diagnostics while hardening report accounting:
    -- lifecycle state remains local to the stand and never drives construction itself.
    spec.lifecycleCompletedTargets = {}
    spec.lifecycleWasEmpty = nil
    spec.interactionNode = self.xmlFile:getValue(
        key .. "#interactionNode",
        spec.searchNode,
        self.components,
        self.i3dMappings
    )
    spec.tabsNode = self.xmlFile:getValue(
        key .. "#tabsNode",
        nil,
        self.components,
        self.i3dMappings
    )
    spec.documentTabs = {}
    if spec.tabsNode ~= nil and spec.tabsNode ~= 0 then
        for childIndex = 0, getNumOfChildren(spec.tabsNode) - 1 do
            local group = getChildAt(spec.tabsNode, childIndex)
            local active = getNumOfChildren(group) > 1 and getChildAt(group, 1) or nil
            table.insert(spec.documentTabs, {group=group, active=active})
            setVisibility(group, false)
            if active ~= nil then
                setVisibility(active, false)
            end
        end
        setVisibility(spec.tabsNode, false)
    end

    -- Persistent tab membership is filled by loadFromXMLFile(), which FS25 calls
    -- with the specialization-scoped savegame key before onFinalizePlacement().
    spec.savedTargetIds = {}
    spec.savedTargetSnapshots = {}
    -- A loaded stand must restore exactly its own historical tab set, including
    -- the valid case of an empty set. New stands may perform the active-site scan.
    spec.restoreExactTargetList = savegame ~= nil

    -- Runtime registry. It is built once after finalization and then maintained
    -- only from lifecycle messages.
    spec.targets = {}
    spec.targetByUniqueId = {}
    spec.registryInitialized = false
    spec.registryInitialScanCount = 0
    spec.registryAddEventCount = 0
    spec.registryRemoveEventCount = 0
    spec.lifecycleSubscribed = false
    spec.lastPlacementSearchSignature = nil
    spec.mpRegistryAuthoritativeReceived = false
    spec.mpTargetObjectsByUniqueId = {}
    spec.mpResolveTimerMs = 0
    spec.mpPendingTargetCount = 0

    self.spec_constructionProgressDisplay = spec

    logInfo(
        "Loaded stand XML=%s savegame=%s boughtWithFarmland=%s searchRadius=%.3f",
        tostring(self.configFileName),
        tostring(savegame ~= nil),
        tostring(self.boughtWithFarmland),
        spec.searchRadius
    )
end

function CPD:getCanBePlacedAt(superFunc, x, y, z, farmId)
    local canBePlaced, message = superFunc(self, x, y, z, farmId)
    if not canBePlaced then
        return false, message
    end

    -- Placement preview is the one deliberate continuous global scan: the
    -- player can move the preview every frame, so proximity must be validated
    -- against the current preview position in real time.
    local nearby = scanNearbyConstructibles(self, false)
    local activeNearby = scanNearbyConstructibles(self, true)
    local spec = self[SPEC_KEY]

    -- Log only when the nearby-target state changes so the preview test does
    -- not flood log.txt every frame.
    if spec ~= nil then
        local nearest = nearby[1]
        local nearestActive = activeNearby[1]
        local nearestId = nearest ~= nil and nearest.uniqueId or nil
        local nearestActiveId = nearestActive ~= nil and nearestActive.uniqueId or nil
        local nearestDistance = nearest ~= nil and math.sqrt(nearest.distanceSq) or nil
        local nearestActiveDistance = nearestActive ~= nil and math.sqrt(nearestActive.distanceSq) or nil

        local signature = string.format(
            "%d|%d|%s|%s",
            #nearby,
            #activeNearby,
            tostring(nearestId),
            tostring(nearestActiveId)
        )
        if signature ~= spec.lastPlacementSearchSignature then
            spec.lastPlacementSearchSignature = signature
            logInfo(
                "Placement search nearby=%d active=%d radius=%.3f nearestId=%s nearestDistance=%s nearestActiveId=%s nearestActiveDistance=%s",
                #nearby,
                #activeNearby,
                spec.searchRadius or 30,
                tostring(nearestId),
                nearestDistance ~= nil and string.format("%.3f", nearestDistance) or "<none>",
                tostring(nearestActiveId),
                nearestActiveDistance ~= nil and string.format("%.3f", nearestActiveDistance) or "<none>"
            )
        end
    end

    if #nearby == 0 then
        return false, g_i18n:getText(
            "warning_constructionProgressDisplay_noConstructionSiteNearby",
            self.customEnvironment
        )
    end

    if #activeNearby == 0 then
        return false, g_i18n:getText(
            "warning_constructionProgressDisplay_noActiveConstructionSiteNearby",
            self.customEnvironment
        )
    end

    return true, nil
end

-- Board-only farmland ownership exception.
--
-- Stock FS25 ConstructionBrushPlaceable:verifyPlacement() checks, in order:
--   getCanBePlacedAt(...)
--   getIsOnOwnedFarmland(...)
--   getHasOverlapWithZones(...)
--   getHasOverlapWithPlaces(...)
--   getHasOverlap(...)
-- Therefore returning true here removes only LAND_UNOWNED for this custom
-- placeable type; restricted zones, water/map bounds, store/load places and
-- physical overlap remain validated by their stock methods.
function CPD:getIsOnOwnedFarmland(superFunc, x, y, z, rotY)
    return true
end


local function isBuildingState(state)
    return state ~= nil
        and ConstructibleStateBuilding ~= nil
        and state.isa ~= nil
        and state:isa(ConstructibleStateBuilding)
end

local function clamp01(value)
    if value < 0 then
        return 0
    elseif value > 1 then
        return 1
    end
    return value
end

local function roundInt(value)
    if value == nil then
        return 0
    end
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

-- GIANTS may finish/finalize a ConstructibleStateBuilding with small residual
-- differences between the configured input amount and the amount observable in
-- remainingAmount/storage.  The report is intentionally an operator-facing
-- estimate, so consumption is rounded independently for every material input of
-- every construction stage.  This also keeps a finished stage stable after the
-- engine clears the construction storage during FINALIZE.
local function getStageConsumptionRoundStep(stageRequiredAmount)
    local amount = tonumber(stageRequiredAmount) or 0
    if amount <= 100 then
        return 10
    elseif amount <= 500 then
        return 20
    end
    return 50
end

local function roundStageAmountUp(value, stageRequiredAmount)
    local amount = math.max(0, tonumber(value) or 0)
    local required = math.max(0, tonumber(stageRequiredAmount) or 0)
    if amount <= 0 or required <= 0 then
        return 0
    end

    local step = getStageConsumptionRoundStep(required)
    -- GIANTS often leaves values such as 48.999999/994.999999 in runtime
    -- calculations. Subtract a tiny epsilon so an already exact multiple is
    -- not accidentally promoted to the next step by floating point noise.
    local epsilon = 0.0001
    return math.ceil(math.max(0, amount - epsilon) / step) * step
end

local function roundStageConsumption(consumedRaw, stageRequiredAmount)
    local consumed = math.max(0, tonumber(consumedRaw) or 0)
    local required = math.max(0, tonumber(stageRequiredAmount) or 0)
    if consumed <= 0 or required <= 0 then
        return 0
    end

    local rounded = roundStageAmountUp(consumed, required)
    local roundedStageMaximum = roundStageAmountUp(required, required)

    -- A partial stage must never report more than the rounded requirement of
    -- that stage.
    return math.max(0, math.min(rounded, roundedStageMaximum))
end

local function formatAmount(value, forceSign)
    local n = roundInt(value)
    local sign = ""
    if n < 0 then
        sign = "-"
        n = -n
    elseif forceSign and n > 0 then
        sign = "+"
    end

    local raw = tostring(n)
    local parts = {}
    while #raw > 3 do
        table.insert(parts, 1, string.sub(raw, -3))
        raw = string.sub(raw, 1, #raw - 3)
    end
    table.insert(parts, 1, raw)

    return sign .. table.concat(parts, " ")
end

local function getLocalizedText(key, environment)
    if g_i18n == nil then
        return key
    end
    return g_i18n:getText(key, environment)
end

local function getTargetOwnerName(target)
    if target ~= nil and target.getOwnerFarmId ~= nil and g_farmManager ~= nil then
        local farmId = target:getOwnerFarmId()
        local farm = g_farmManager:getFarmById(farmId)
        if farm ~= nil and farm.name ~= nil and farm.name ~= "" then
            return farm.name
        end
    end

    return "Lizarrd building inc"
end

local function getConfiguredStateDisplayName(target, stateIndex)
    if target == nil
        or target.xmlFile == nil
        or stateIndex == nil
        or stateIndex < 1 then
        return nil
    end

    local key = string.format(
        "placeable.constructible.stateMachine.states.state(%d)#StateName",
        stateIndex - 1
    )

    local value = nil
    if target.xmlFile.getI18NValue ~= nil then
        value = target.xmlFile:getI18NValue(key, nil, target.customEnvironment, false)
    else
        value = target.xmlFile:getValue(key)
    end

    if value == nil then
        return nil
    end

    value = tostring(value)
    if string.match(value, "^%s*$") then
        return nil
    end

    return value
end

local function collectBarFillNodes(groupNode, maxCount)
    local result = {}
    if groupNode == nil or groupNode == 0 then
        return result
    end
    local count = math.min(getNumOfChildren(groupNode), maxCount or math.huge)
    for i = 0, count - 1 do
        local barGroup = getChildAt(groupNode, i)
        if barGroup ~= nil and barGroup ~= 0 and getNumOfChildren(barGroup) >= 2 then
            result[#result + 1] = {
                group = barGroup,
                track = getChildAt(barGroup, 0),
                fill = getChildAt(barGroup, 1)
            }
        end
    end
    return result
end

local function updateBarEntry(bar, factor, width, height)
    if bar == nil or bar.group == nil then
        return
    end
    if factor == nil then
        setVisibility(bar.group, false)
        return
    end
    setVisibility(bar.group, true)
    local fill = bar.fill
    factor = clamp01(tonumber(factor) or 0)
    if factor <= 0.0001 then
        setVisibility(fill, false)
    else
        setVisibility(fill, true)
        local w = width * factor
        setScale(fill, w, height, 0.004)
        local _, fy, fz = getTranslation(fill)
        setTranslation(fill, w * 0.5, fy, fz)
    end
end

local function updateProgressVisuals(self, report)
    local spec = self ~= nil and self[SPEC_KEY] or nil
    if spec == nil then
        return
    end

    -- Stage 06G uses text/numeric progress only. The large overall bar and all
    -- material/stage bars were removed from the approved layout. Keep the old
    -- geometry hidden so it cannot overlap the official table.
    if spec.progressBarsNode ~= nil and spec.progressBarsNode ~= 0 then
        setVisibility(spec.progressBarsNode, false)
    end

    if spec.reportFormNode ~= nil and spec.reportFormNode ~= 0 then
        setVisibility(spec.reportFormNode, report ~= nil and not report.noTarget)
    end

    if spec.tabsNode ~= nil and spec.tabsNode ~= 0 then
        local count = report ~= nil and not report.noTarget and (report.targetCount or 0) or 0
        local selected = report ~= nil and (report.targetIndex or 1) or 1
        local shown = math.min(count, #spec.documentTabs)
        local first = 1
        if count > #spec.documentTabs then
            first = math.max(1, math.min(selected - 2, count - #spec.documentTabs + 1))
        end
        setVisibility(spec.tabsNode, count > 1)
        for slot, tab in ipairs(spec.documentTabs) do
            local actualIndex = first + slot - 1
            local visible = count > 1 and slot <= shown and actualIndex <= count
            setVisibility(tab.group, visible)
            if tab.active ~= nil then
                setVisibility(tab.active, visible and actualIndex == selected)
            end
        end
        spec.visibleTabStart = first
    end
end

local function getPalletCapacityForFillType(fillTypeIndex)
    local cached = CPD.palletCapacityCache[fillTypeIndex]
    if cached ~= nil then
        return type(cached) == "number" and cached or nil
    end

    local capacity = nil
    local fillType = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
    local palletFilename = fillType ~= nil and fillType.palletFilename or nil

    -- Use the same StoreItem specs path that is already proven in the map's
    -- pallet-price code. It yields the configured fill-unit capacity as a
    -- number and avoids relying on an undocumented return shape here.
    if palletFilename ~= nil
        and palletFilename ~= ""
        and g_storeManager ~= nil
        and g_storeManager.getItemByXMLFilename ~= nil then

        local storeItem = g_storeManager:getItemByXMLFilename(palletFilename)
        if storeItem ~= nil then
            if storeItem.specs == nil
                and StoreItemUtil ~= nil
                and StoreItemUtil.loadSpecsFromXML ~= nil then
                StoreItemUtil.loadSpecsFromXML(storeItem)
            end

            local capacitySpecs = storeItem.specs ~= nil and storeItem.specs.capacity or nil
            if type(capacitySpecs) == "table" then
                local capacityConfig = capacitySpecs[1]
                local fillUnits = capacityConfig ~= nil and capacityConfig.fillUnits or nil
                if type(fillUnits) == "table" then
                    for _, fillUnit in ipairs(fillUnits) do
                        local candidate = fillUnit ~= nil and fillUnit.capacity or nil
                        if type(candidate) == "number" and candidate > 0 then
                            capacity = candidate
                            break
                        end
                    end
                end
            end
        end
    end

    if type(capacity) == "number" and capacity > 0 then
        CPD.palletCapacityCache[fillTypeIndex] = capacity
        return capacity
    end

    CPD.palletCapacityCache[fillTypeIndex] = false
    return nil
end

local function getRoundedRequiredAmount(requiredRaw, fillTypeIndex)
    if requiredRaw == nil or requiredRaw <= 0 then
        return 0, nil
    end

    local roundedBy1000 = math.ceil(requiredRaw / 1000) * 1000
    local palletCapacity = getPalletCapacityForFillType(fillTypeIndex)

    if type(palletCapacity) == "number" and palletCapacity > 0 then
        local roundedByPallet = math.ceil(requiredRaw / palletCapacity) * palletCapacity
        local palletExcess = roundedByPallet - requiredRaw
        if palletExcess <= 1000 then
            return roundedByPallet, palletCapacity
        end
    end

    return roundedBy1000, palletCapacity
end

local function markReportDirty(self)
    local spec = self ~= nil and self[SPEC_KEY] or nil
    if spec ~= nil then
        spec.reportDirty = true
    end
end

local function copyStorageLevels(storage)
    local snapshot = {}
    local total = 0

    if storage ~= nil and storage.getFillLevels ~= nil then
        local fillLevels = storage:getFillLevels()
        if fillLevels ~= nil then
            for fillTypeIndex, level in pairs(fillLevels) do
                local numericLevel = math.max(0, tonumber(level) or 0)
                snapshot[fillTypeIndex] = numericLevel
                total = total + numericLevel
            end
        end
    end

    return snapshot, total
end

local function copySnapshot(snapshot)
    local result = {}
    if snapshot ~= nil then
        for fillTypeIndex, level in pairs(snapshot) do
            result[fillTypeIndex] = level
        end
    end
    return result
end

local function attachTargetStorageListener(self, entry)
    if entry == nil or entry.storageListener ~= nil or not self.isClient then
        return
    end

    local targetSpec = entry.placeable ~= nil and entry.placeable.spec_constructible or nil
    local storage = targetSpec ~= nil and targetSpec.storage or nil
    if storage ~= nil and storage.addFillLevelChangedListeners ~= nil then
        entry.lastObservedStorageSnapshot = select(1, copyStorageLevels(storage))
        entry.lastFallbackSnapshotTimeMs = g_time or 0

        entry.storageListener = function()
            -- Storage changes can happen every simulation tick while building.
            -- They only mark cached report data stale; they no longer trigger an
            -- immediate rebuild. The fallback snapshot is sampled at most once
            -- per second, while the normal finalization hook captures the exact
            -- value immediately before GIANTS clears the storage.
            markReportDirty(self)

            local now = g_time or 0
            if now - (entry.lastFallbackSnapshotTimeMs or 0) >= FALLBACK_STORAGE_SNAPSHOT_INTERVAL_MS then
                local snapshot, total = copyStorageLevels(storage)
                if isActiveConstructible(entry.placeable) or total > 0 then
                    entry.lastObservedStorageSnapshot = snapshot
                end
                entry.lastFallbackSnapshotTimeMs = now
            end
        end
        storage:addFillLevelChangedListeners(entry.storageListener)
    end
end

local function detachTargetStorageListener(entry)
    if entry == nil or entry.storageListener == nil then
        return
    end

    local targetSpec = entry.placeable ~= nil and entry.placeable.spec_constructible or nil
    local storage = targetSpec ~= nil and targetSpec.storage or nil
    if storage ~= nil and storage.removeFillLevelChangedListeners ~= nil then
        storage:removeFillLevelChangedListeners(entry.storageListener)
    end
    entry.storageListener = nil
end

function CPD:setConstructionProgressDisplaySelectedTarget(targetUniqueId, source)
    local spec = self[SPEC_KEY]
    if spec == nil or targetUniqueId == nil or targetUniqueId == "" then return false end
    targetUniqueId = tostring(targetUniqueId)
    if spec.registryInitialized and spec.targetByUniqueId[targetUniqueId] == nil then
        logInfo("Rejected selected tab standId=%s targetId=%s source=%s reason=NOT_IN_REGISTRY", tostring(getPlaceableUniqueId(self)), targetUniqueId, tostring(source))
        return false
    end
    spec.selectedTargetUniqueId = targetUniqueId
    spec.stagePageStart = nil
    spec.materialPageStart = 1
    spec.reportDirty = true
    spec.reportForceRefresh = true
    spec.lastReportLogSignature = nil
    local entry = spec.targetByUniqueId[targetUniqueId]
    logInfo("Selected tab applied standId=%s targetId=%s name=%q source=%s", tostring(getPlaceableUniqueId(self)), targetUniqueId, tostring(entry ~= nil and getPlaceableName(entry.placeable) or "<pending>"), tostring(source))
    return true
end

local function ensureSelectedTarget(spec)
    if spec == nil then
        return nil, nil
    end

    if spec.selectedTargetUniqueId ~= nil then
        local selected = spec.targetByUniqueId[spec.selectedTargetUniqueId]
        if selected ~= nil then
            local selectedIndex = 1
            for index, entry in ipairs(spec.targets) do
                if entry == selected then
                    selectedIndex = index
                    break
                end
            end
            return selected, selectedIndex
        end
    end

    local first = spec.targets[1]
    spec.selectedTargetUniqueId = first ~= nil and first.uniqueId or nil
    return first, first ~= nil and 1 or nil
end

local function selectNextTarget(stand)
    local spec = stand ~= nil and stand[SPEC_KEY] or nil
    if spec == nil or spec.targets == nil or #spec.targets <= 1 then
        return false
    end

    local _, currentIndex = ensureSelectedTarget(spec)
    currentIndex = currentIndex or 1
    local nextIndex = currentIndex % #spec.targets + 1
    local nextEntry = spec.targets[nextIndex]
    if nextEntry == nil then
        return false
    end

    stand:setConstructionProgressDisplaySelectedTarget(nextEntry.uniqueId, "LOCAL_PLAYER")
    logInfo(
        "Selected tab changed locally standId=%s index=%d/%d targetId=%s name=%q",
        tostring(getPlaceableUniqueId(stand)),
        nextIndex,
        #spec.targets,
        tostring(nextEntry.uniqueId),
        tostring(getPlaceableName(nextEntry.placeable))
    )
    return true
end

local function cycleStagePage(stand)
    local spec = stand ~= nil and stand[SPEC_KEY] or nil
    local report = spec ~= nil and spec.reportData or nil
    if report == nil or report.noTarget or (report.totalStages or 0) <= MAX_VISIBLE_STAGES then
        return false
    end

    local currentStart = report.visibleStageStart or 1
    local nextStart = currentStart + MAX_VISIBLE_STAGES
    if nextStart > (report.totalStages or 0) then
        nextStart = 1
    end
    spec.stagePageStart = nextStart
    spec.reportDirty = true
    spec.reportForceRefresh = true
    spec.lastReportLogSignature = nil
    logInfo(
        "Stage page changed standId=%s start=%d totalStages=%d",
        tostring(getPlaceableUniqueId(stand)), nextStart, report.totalStages or 0
    )
    return true
end

local function cycleMaterialPage(stand)
    local spec = stand ~= nil and stand[SPEC_KEY] or nil
    local report = spec ~= nil and spec.reportData or nil
    local totalMaterials = report ~= nil and report.materials ~= nil and #report.materials or 0
    if report == nil or report.noTarget or totalMaterials <= MAX_VISIBLE_MATERIALS then
        return false
    end

    local currentStart = report.materialPageStart or 1
    local nextStart = currentStart + MAX_VISIBLE_MATERIALS
    if nextStart > totalMaterials then
        nextStart = 1
    end
    spec.materialPageStart = nextStart
    spec.reportDirty = true
    spec.reportForceRefresh = true
    spec.lastReportLogSignature = nil
    logInfo(
        "Material page changed standId=%s start=%d totalMaterials=%d",
        tostring(getPlaceableUniqueId(stand)), nextStart, totalMaterials
    )
    return true
end

local function getTargetStoreImageFilename(target)
    if target == nil or target.configFileName == nil or g_storeManager == nil
        or g_storeManager.getItemByXMLFilename == nil then
        return nil
    end

    local storeItem = g_storeManager:getItemByXMLFilename(target.configFileName)
    local filename = storeItem ~= nil and storeItem.imageFilename or nil
    if filename ~= nil and filename ~= "" and textureFileExists(filename) then
        return filename
    end
    return nil
end

local function buildReportData(self)
    local spec = self[SPEC_KEY]
    local selectedEntry, selectedIndex = ensureSelectedTarget(spec)

    if selectedEntry == nil
        or selectedEntry.placeable == nil
        or not isCompatibleConstructible(selectedEntry.placeable) then
        return {
            noTarget = true,
            targetCount = spec ~= nil and #spec.targets or 0
        }
    end

    local target = selectedEntry.placeable
    local constructible = target.spec_constructible
    if constructible == nil
        or constructible.stateMachine == nil
        or constructible.storage == nil then
        return {
            noTarget = true,
            targetCount = spec ~= nil and #spec.targets or 0
        }
    end

    local stateIndex = constructible.stateIndex or -1
    local currentState = constructible.stateMachine[stateIndex]

    local totalBuildingStages = 0
    local completedBuildingStages = 0
    local currentPartial = 0
    local currentBuildingOrdinal = nil
    local materialsByFillType = {}
    local materials = {}
    local stages = {}
    local nextMaterialOrder = 1

    for index, state in ipairs(constructible.stateMachine) do
        if isBuildingState(state) then
            totalBuildingStages = totalBuildingStages + 1

            local isCompleted = index < stateIndex
            local isCurrent = index == stateIndex
            if isCompleted then
                completedBuildingStages = completedBuildingStages + 1
            elseif isCurrent then
                currentBuildingOrdinal = totalBuildingStages
            end

            local stateTotal = state.totalAmount or 0
            local stateConsumed = 0
            local stageMaterialConsumption = {}

            for _, input in ipairs(state.inputs or {}) do
                local fillType = input.fillType
                local fillTypeIndex = fillType ~= nil and fillType.index or nil
                local amount = input.amount or 0

                if fillTypeIndex ~= nil then
                    local material = materialsByFillType[fillTypeIndex]
                    if material == nil then
                        material = {
                            fillTypeIndex = fillTypeIndex,
                            fillTypeName = fillType.name,
                            title = fillType.title
                                or (g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex))
                                or fillType.name
                                or tostring(fillTypeIndex),
                            requiredRaw = 0,
                            requiredRounded = 0,
                            consumedRaw = 0,
                            consumed = 0,
                            order = nextMaterialOrder
                        }
                        nextMaterialOrder = nextMaterialOrder + 1
                        materialsByFillType[fillTypeIndex] = material
                        table.insert(materials, material)
                    end

                    material.requiredRaw = material.requiredRaw + amount

                    local consumedNow = 0
                    if isCompleted then
                        consumedNow = amount
                    elseif isCurrent then
                        local remaining = input.remainingAmount or amount
                        consumedNow = math.max(0, math.min(amount, amount - remaining))

                        -- Construction-stage progress must stay based on the exact
                        -- runtime values. Only the operator-facing material column
                        -- is rounded.
                        stateConsumed = stateConsumed + consumedNow
                    end

                    material.consumedRaw = material.consumedRaw + consumedNow

                    local stageConsumption = stageMaterialConsumption[fillTypeIndex]
                    if stageConsumption == nil then
                        stageConsumption = {
                            material = material,
                            requiredAmount = 0,
                            consumedRaw = 0
                        }
                        stageMaterialConsumption[fillTypeIndex] = stageConsumption
                    end
                    stageConsumption.requiredAmount = stageConsumption.requiredAmount + amount
                    stageConsumption.consumedRaw = stageConsumption.consumedRaw + consumedNow
                end
            end

            -- Round once per material per construction stage. This is important
            -- even if a custom constructible defines the same fill type through
            -- more than one input entry inside one state.
            for _, stageConsumption in pairs(stageMaterialConsumption) do
                -- Both sides of the material balance use the same per-stage
                -- upward rounding. This is intentionally independent from
                -- pallet capacity: pallet size is a procurement detail, not the
                -- construction's actual material requirement.
                stageConsumption.material.requiredRounded =
                    stageConsumption.material.requiredRounded
                    + roundStageAmountUp(stageConsumption.requiredAmount, stageConsumption.requiredAmount)

                stageConsumption.material.consumed = stageConsumption.material.consumed
                    + roundStageConsumption(stageConsumption.consumedRaw, stageConsumption.requiredAmount)
            end

            if isCurrent and stateTotal > 0 then
                currentPartial = clamp01(stateConsumed / stateTotal)
            end

            local stageProgress = 0
            if isCompleted then
                stageProgress = 1
            elseif isCurrent then
                stageProgress = currentPartial
            end
            table.insert(stages, {
                ordinal = totalBuildingStages,
                stateIndex = index,
                stateName = state.name,
                displayName = getConfiguredStateDisplayName(target, index),
                progress = stageProgress
            })
        end
    end

    if totalBuildingStages > 0 and currentBuildingOrdinal == nil then
        if completedBuildingStages >= totalBuildingStages then
            currentBuildingOrdinal = totalBuildingStages
            currentPartial = 1
        else
            currentBuildingOrdinal = completedBuildingStages + 1
            currentPartial = 0
        end
    end

    local progress = 0
    if totalBuildingStages > 0 then
        if completedBuildingStages >= totalBuildingStages then
            progress = 1
        else
            progress = clamp01((completedBuildingStages + currentPartial) / totalBuildingStages)
        end
    end

    local isComplete = totalBuildingStages > 0
        and completedBuildingStages >= totalBuildingStages
        and currentBuildingOrdinal == totalBuildingStages

    local finalStorageSnapshot = nil
    if isComplete then
        finalStorageSnapshot = selectedEntry.finalStorageSnapshot
            or selectedEntry.lastObservedStorageSnapshot
    end

    for _, material in ipairs(materials) do
        if finalStorageSnapshot ~= nil then
            material.stored = finalStorageSnapshot[material.fillTypeIndex] or 0
        else
            material.stored = constructible.storage:getFillLevel(material.fillTypeIndex)
        end
        material.supplied = material.consumed + material.stored

        material.palletCapacity = getPalletCapacityForFillType(material.fillTypeIndex)
        material.balance = material.supplied - material.requiredRounded
    end

    table.sort(materials, function(a, b)
        return a.order < b.order
    end)

    local visibleStages = {}
    local stagePageCount = math.max(1, math.ceil(#stages / MAX_VISIBLE_STAGES))
    local visibleStageStart = spec.stagePageStart
    if visibleStageStart == nil then
        local currentOrdinal = math.max(1, currentBuildingOrdinal or 1)
        visibleStageStart = math.floor((currentOrdinal - 1) / MAX_VISIBLE_STAGES) * MAX_VISIBLE_STAGES + 1
    end
    local lastStagePageStart = math.max(1, (stagePageCount - 1) * MAX_VISIBLE_STAGES + 1)
    visibleStageStart = math.max(1, math.min(visibleStageStart, lastStagePageStart))
    visibleStageStart = math.floor((visibleStageStart - 1) / MAX_VISIBLE_STAGES) * MAX_VISIBLE_STAGES + 1
    for i = visibleStageStart, math.min(#stages, visibleStageStart + MAX_VISIBLE_STAGES - 1) do
        visibleStages[#visibleStages + 1] = stages[i]
    end

    local materialPageCount = math.max(1, math.ceil(#materials / MAX_VISIBLE_MATERIALS))
    local materialPageStart = tonumber(spec.materialPageStart) or 1
    local lastMaterialPageStart = math.max(1, (materialPageCount - 1) * MAX_VISIBLE_MATERIALS + 1)
    materialPageStart = math.max(1, math.min(materialPageStart, lastMaterialPageStart))
    materialPageStart = math.floor((materialPageStart - 1) / MAX_VISIBLE_MATERIALS) * MAX_VISIBLE_MATERIALS + 1
    local visibleMaterials = {}
    for i = materialPageStart, math.min(#materials, materialPageStart + MAX_VISIBLE_MATERIALS - 1) do
        visibleMaterials[#visibleMaterials + 1] = materials[i]
    end

    return {
        noTarget = false,
        target = target,
        targetId = selectedEntry.uniqueId,
        targetIndex = selectedIndex or 1,
        targetCount = #spec.targets,
        targetName = getPlaceableName(target),
        targetImageFilename = getTargetStoreImageFilename(target),
        responsible = getTargetOwnerName(target),
        stateIndex = stateIndex,
        stateName = currentState ~= nil and currentState.name or "?",
        stateDisplayName = getConfiguredStateDisplayName(target, stateIndex),
        stageOrdinal = currentBuildingOrdinal or 0,
        totalStages = totalBuildingStages,
        completedStages = completedBuildingStages,
        currentPartial = currentPartial,
        progress = progress,
        progressPercent = progress * 100,
        isComplete = isComplete,
        stages = stages,
        visibleStages = visibleStages,
        visibleStageStart = visibleStageStart,
        stagePageCount = stagePageCount,
        materials = materials,
        visibleMaterials = visibleMaterials,
        materialPageStart = materialPageStart,
        materialPageCount = materialPageCount
    }
end

local function getReportLogSignature(report)
    if report == nil or report.noTarget then
        return string.format("none|%d", report ~= nil and report.targetCount or 0)
    end

    return string.format(
        "%s|%d|%s|%d|%d|%d|%d",
        tostring(report.targetId),
        report.stateIndex or -1,
        tostring(report.stateName),
        report.stageOrdinal or 0,
        report.totalStages or 0,
        math.floor((report.progressPercent or 0) + 0.5),
        math.floor((report.currentPartial or 0) * 100 + 0.5)
    )
end

local function logReportSnapshot(self, report)
    if not DETAILED_REPORT_LOGGING then
        return
    end

    local spec = self[SPEC_KEY]
    if spec == nil or report == nil then
        return
    end

    local signature = getReportLogSignature(report)
    if signature == spec.lastReportLogSignature then
        return
    end
    spec.lastReportLogSignature = signature

    if report.noTarget then
        logInfo(
            "Report snapshot standId=%s target=<none> targetCount=%d",
            tostring(getPlaceableUniqueId(self)),
            report.targetCount or 0
        )
        return
    end

    logInfo(
        "Report snapshot standId=%s targetId=%s name=%q page=%d/%d stateIndex=%d stateName=%s StateName=%q stage=%d/%d stageProgress=%.2f progress=%.2f responsible=%q materials=%d",
        tostring(getPlaceableUniqueId(self)),
        tostring(report.targetId),
        tostring(report.targetName),
        report.targetIndex or 1,
        report.targetCount or 1,
        report.stateIndex or -1,
        tostring(report.stateName),
        tostring(report.stateDisplayName),
        report.stageOrdinal or 0,
        report.totalStages or 0,
        (report.currentPartial or 0) * 100,
        report.progressPercent or 0,
        tostring(report.responsible),
        #report.materials
    )

    for index, stage in ipairs(report.visibleStages or {}) do
        logInfo(
            "Report stage[%d] ordinal=%d stateIndex=%d stateName=%s StateName=%q progress=%.2f",
            index,
            stage.ordinal or 0,
            stage.stateIndex or -1,
            tostring(stage.stateName),
            tostring(stage.displayName),
            (stage.progress or 0) * 100
        )
    end

    for index, material in ipairs(report.materials) do
        logInfo(
            "Report material[%d] fillType=%s title=%q consumedRaw=%.3f consumed=%.3f stored=%.3f supplied=%.3f requiredRaw=%.3f palletCapacity=%s requiredRounded=%.3f balance=%.3f",
            index,
            tostring(material.fillTypeName),
            tostring(material.title),
            material.consumedRaw or 0,
            material.consumed or 0,
            material.stored or 0,
            material.supplied or 0,
            material.requiredRaw or 0,
            material.palletCapacity ~= nil and string.format("%.3f", material.palletCapacity) or "<none>",
            material.requiredRounded or 0,
            material.balance or 0
        )
    end
end

local function updateLifecycleDiagnostics(self, previousReport, report)
    local spec = self[SPEC_KEY]
    if spec == nil or report == nil then
        return
    end

    local isEmpty = report.noTarget == true or (report.targetCount or 0) == 0
    if spec.lifecycleWasEmpty == nil then
        spec.lifecycleWasEmpty = isEmpty
        if isEmpty then
            logInfo(
                "Lifecycle EMPTY standId=%s reason=INITIAL targetCount=0",
                tostring(getPlaceableUniqueId(self))
            )
        end
    elseif isEmpty ~= spec.lifecycleWasEmpty then
        if isEmpty then
            logInfo(
                "Lifecycle EMPTY standId=%s reason=LAST_TARGET_REMOVED targetCount=0",
                tostring(getPlaceableUniqueId(self))
            )
        else
            logInfo(
                "Lifecycle RECOVERED standId=%s targetCount=%d selectedTargetId=%s",
                tostring(getPlaceableUniqueId(self)),
                report.targetCount or 0,
                tostring(report.targetId)
            )
        end
        spec.lifecycleWasEmpty = isEmpty
    end

    if not report.noTarget and report.targetId ~= nil and report.isComplete then
        local targetId = tostring(report.targetId)
        if spec.lifecycleCompletedTargets[targetId] ~= true then
            spec.lifecycleCompletedTargets[targetId] = true

            local trackedEntry = spec.targetByUniqueId ~= nil
                and spec.targetByUniqueId[targetId]
                or nil
            if trackedEntry ~= nil
                and trackedEntry.finalStorageSnapshot == nil
                and trackedEntry.lastObservedStorageSnapshot ~= nil then
                trackedEntry.finalStorageSnapshot =
                    copySnapshot(trackedEntry.lastObservedStorageSnapshot)

                local fallbackTotal = 0
                local fallbackCount = 0
                for _, level in pairs(trackedEntry.finalStorageSnapshot) do
                    fallbackTotal = fallbackTotal + level
                    fallbackCount = fallbackCount + 1
                end

                logInfo(
                    "FINAL STORAGE FALLBACK standId=%s targetId=%s entries=%d total=%.3f",
                    tostring(getPlaceableUniqueId(self)),
                    targetId,
                    fallbackCount,
                    fallbackTotal
                )
            end

            local storedTotal = 0
            local consumedRawTotal = 0
            local consumedTotal = 0
            local requiredRawTotal = 0
            for _, material in ipairs(report.materials or {}) do
                storedTotal = storedTotal + (material.stored or 0)
                consumedRawTotal = consumedRawTotal + (material.consumedRaw or 0)
                consumedTotal = consumedTotal + (material.consumed or 0)
                requiredRawTotal = requiredRawTotal + (material.requiredRaw or 0)
            end

            logInfo(
                "Lifecycle COMPLETE standId=%s targetId=%s name=%q stateIndex=%d stateName=%s stages=%d/%d progress=%.2f storedTotal=%.3f consumedRawTotal=%.3f consumedTotal=%.3f requiredRawTotal=%.3f",
                tostring(getPlaceableUniqueId(self)),
                targetId,
                tostring(report.targetName),
                report.stateIndex or -1,
                tostring(report.stateName),
                report.completedStages or 0,
                report.totalStages or 0,
                report.progressPercent or 0,
                storedTotal,
                consumedRawTotal,
                consumedTotal,
                requiredRawTotal
            )
        end
    end
end

local function refreshReportData(self)
    local spec = self[SPEC_KEY]
    if spec == nil then
        return
    end

    local previousReport = spec.reportData
    spec.reportData = buildReportData(self)
    spec.reportDirty = false
    spec.reportForceRefresh = false
    spec.reportRefreshTimerMs = 0
    updateProgressVisuals(self, spec.reportData)
    updateLifecycleDiagnostics(self, previousReport, spec.reportData)
    logReportSnapshot(self, spec.reportData)
end


local function captureFinalStorageSnapshotForTrackedTarget(target)
    if target == nil or target.spec_constructible == nil then
        return
    end

    local targetId = getPlaceableUniqueId(target)
    local storage = target.spec_constructible.storage
    if targetId == nil or storage == nil then
        return
    end

    local snapshot = select(1, copyStorageLevels(storage))

    for _, stand in ipairs(CPD.trackedStands) do
        local spec = stand ~= nil and stand[SPEC_KEY] or nil
        local entry = spec ~= nil
            and spec.targetByUniqueId ~= nil
            and spec.targetByUniqueId[targetId]
            or nil
        if entry ~= nil then
            entry.finalStorageSnapshot = {}
            for fillTypeIndex, level in pairs(snapshot) do
                entry.finalStorageSnapshot[fillTypeIndex] = level
            end
            spec.reportDirty = true
            if stand.isClient then
                spec.reportForceRefresh = true
            end

            local total = 0
            local entryCount = 0
            for _, level in pairs(entry.finalStorageSnapshot) do
                total = total + level
                entryCount = entryCount + 1
            end
            logInfo(
                "FINAL STORAGE SNAPSHOT standId=%s targetId=%s name=%q entries=%d total=%.3f",
                tostring(getPlaceableUniqueId(stand)),
                tostring(targetId),
                tostring(getPlaceableName(target)),
                entryCount,
                total
            )
        end
    end
end

installConstructibleFinalizeHook = function()
    if CPD.constructibleFinalizeHookInstalled then
        return
    end

    if PlaceableConstructible == nil
        or PlaceableConstructible.finalizeConstruction == nil then
        Logging.warning("%s PlaceableConstructible.finalizeConstruction hook unavailable", LOG_PREFIX)
        return
    end

    PlaceableConstructible.finalizeConstruction = Utils.overwrittenFunction(
        PlaceableConstructible.finalizeConstruction,
        function(placeable, superFunc)
            -- GIANTS empties constructible.storage at the beginning of
            -- finalizeConstruction(). Snapshot the remaining surplus first.
            captureFinalStorageSnapshotForTrackedTarget(placeable)
            return superFunc(placeable)
        end
    )
    CPD.constructibleFinalizeHookInstalled = true
    logInfo("PlaceableConstructible.finalizeConstruction pre-empty snapshot hook installed")
end

function CPD:subscribeConstructionProgressDisplayLifecycle()
    local spec = self[SPEC_KEY]
    if spec == nil or spec.lifecycleSubscribed then
        return
    end

    g_messageCenter:subscribe(MessageType.PLACEABLE_ADDED, CPD.onPlaceableAdded, self)
    g_messageCenter:subscribe(MessageType.PLACEABLE_REMOVED, CPD.onPlaceableRemoved, self)
    spec.lifecycleSubscribed = true

    logInfo(
        "Registry subscribed standId=%s messages=PLACEABLE_ADDED,PLACEABLE_REMOVED",
        tostring(getPlaceableUniqueId(self))
    )
end

function CPD:initializeConstructionProgressDisplayRegistry()
    local spec = self[SPEC_KEY]
    if spec == nil or spec.registryInitialized then
        return
    end

    spec.targets = {}
    spec.targetByUniqueId = {}
    spec.registryInitialScanCount = spec.registryInitialScanCount + 1

    -- New stand: register only construction sites that are active at the moment
    -- the stand is finalized. Completed sites in range must not appear.
    --
    -- Loaded stand: restore the exact saved tab membership, including sites
    -- that have completed since registration. This makes tab membership a
    -- property of this stand instead of a fresh proximity query after every load.
    local initialTargets = {}
    if spec.restoreExactTargetList == true then
        local savedById = {}
        for _, savedId in ipairs(spec.savedTargetIds) do
            savedById[tostring(savedId)] = true
        end

        if g_currentMission ~= nil
            and g_currentMission.placeableSystem ~= nil
            and g_currentMission.placeableSystem.placeables ~= nil then
            for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
                if isCompatibleConstructible(placeable) then
                    local uniqueId = getPlaceableUniqueId(placeable)
                    if uniqueId ~= nil and savedById[tostring(uniqueId)] then
                        local distanceSq = getHorizontalDistanceSqToStand(self, placeable) or math.huge
                        table.insert(initialTargets, {
                            placeable = placeable,
                            uniqueId = uniqueId,
                            distanceSq = distanceSq,
                            finalStorageSnapshot = spec.savedTargetSnapshots[tostring(uniqueId)]
                        })
                    end
                end
            end
        end
    else
        initialTargets = scanNearbyConstructibles(self, true)
    end

    for _, entry in ipairs(initialTargets) do
        local uniqueId = entry.uniqueId
        if uniqueId ~= nil and spec.targetByUniqueId[uniqueId] == nil then
            table.insert(spec.targets, entry)
            spec.targetByUniqueId[uniqueId] = entry
            attachTargetStorageListener(self, entry)
        end
    end

    sortTargetRegistry(spec)
    spec.registryInitialized = true
    -- Every client starts from the first local tab after load.
    -- No shared/server-authoritative selected tab is maintained.
    spec.selectedTargetUniqueId = nil
    ensureSelectedTarget(spec)
    spec.reportDirty = true
    spec.reportForceRefresh = true

    logInfo(
        "Registry initialized standId=%s targetCount=%d radius=%.3f fullScans=%d",
        tostring(getPlaceableUniqueId(self)),
        #spec.targets,
        spec.searchRadius or 30,
        spec.registryInitialScanCount
    )

    for index, entry in ipairs(spec.targets) do
        logInfo(
            "Registry target[%d] id=%s name=%q distance=%.3f",
            index,
            tostring(entry.uniqueId),
            tostring(getPlaceableName(entry.placeable)),
            math.sqrt(entry.distanceSq)
        )
    end
end

local function getSavedTargetSnapshot(spec, uniqueId)
    if spec == nil or uniqueId == nil or spec.savedTargetIds == nil then
        return false, nil
    end
    uniqueId = tostring(uniqueId)
    for _, savedId in ipairs(spec.savedTargetIds) do
        if tostring(savedId) == uniqueId then
            return true, spec.savedTargetSnapshots ~= nil
                and spec.savedTargetSnapshots[uniqueId]
                or nil
        end
    end
    return false, nil
end

function CPD:addConstructionProgressDisplayTarget(placeable, reason)
    local spec = self[SPEC_KEY]
    if spec == nil or not spec.registryInitialized then
        return false
    end

    if placeable == self or not isCompatibleConstructible(placeable) then
        return false
    end

    local uniqueId = getPlaceableUniqueId(placeable)
    if uniqueId == nil then
        Logging.warning(
            "%s Cannot register compatible constructible without uniqueId: %s",
            LOG_PREFIX,
            tostring(getPlaceableName(placeable))
        )
        return false
    end

    if spec.targetByUniqueId[uniqueId] ~= nil then
        return false
    end

    local isSavedTarget, savedSnapshot = getSavedTargetSnapshot(spec, uniqueId)
    if not isSavedTarget and not isActiveConstructible(placeable) then
        return false
    end

    local inRange, distanceSq = isWithinSearchRadius(self, placeable)
    if not isSavedTarget and not inRange then
        return false
    end
    distanceSq = distanceSq or (getHorizontalDistanceSqToStand(self, placeable) or math.huge)

    local entry = {
        placeable = placeable,
        uniqueId = uniqueId,
        distanceSq = distanceSq,
        finalStorageSnapshot = savedSnapshot
    }
    table.insert(spec.targets, entry)
    spec.targetByUniqueId[uniqueId] = entry
    attachTargetStorageListener(self, entry)
    sortTargetRegistry(spec)
    ensureSelectedTarget(spec)
    spec.reportDirty = true
    spec.reportForceRefresh = true

    logInfo(
        "Registry ADD standId=%s reason=%s targetId=%s name=%q distance=%.3f targetCount=%d",
        tostring(getPlaceableUniqueId(self)),
        tostring(reason),
        tostring(uniqueId),
        tostring(getPlaceableName(placeable)),
        math.sqrt(distanceSq),
        #spec.targets
    )

    return true
end

function CPD:removeConstructionProgressDisplayTarget(placeable, reason)
    local spec = self[SPEC_KEY]
    if spec == nil or not spec.registryInitialized or placeable == nil then
        return false
    end

    local uniqueId = getPlaceableUniqueId(placeable)
    if uniqueId == nil then
        return false
    end

    local entry = spec.targetByUniqueId[uniqueId]
    if entry == nil then
        return false
    end

    detachTargetStorageListener(entry)
    spec.targetByUniqueId[uniqueId] = nil
    for index = #spec.targets, 1, -1 do
        if spec.targets[index] == entry or spec.targets[index].uniqueId == uniqueId then
            table.remove(spec.targets, index)
            break
        end
    end

    if spec.selectedTargetUniqueId == uniqueId then
        spec.selectedTargetUniqueId = nil
        spec.stagePageStart = nil
        spec.materialPageStart = 1
        ensureSelectedTarget(spec)
    end
    if spec.lifecycleCompletedTargets ~= nil then
        spec.lifecycleCompletedTargets[tostring(uniqueId)] = nil
    end
    spec.reportDirty = true
    spec.reportForceRefresh = true

    logInfo(
        "Registry REMOVE standId=%s reason=%s targetId=%s name=%q targetCount=%d",
        tostring(getPlaceableUniqueId(self)),
        tostring(reason),
        tostring(uniqueId),
        tostring(getPlaceableName(placeable)),
        #spec.targets
    )

    return true
end

function CPD:onPlaceableAdded(placeable)
    local spec = self[SPEC_KEY]
    if spec == nil then
        return
    end

    spec.registryAddEventCount = spec.registryAddEventCount + 1
    self:addConstructionProgressDisplayTarget(placeable, "PLACEABLE_ADDED")
end

function CPD:onPlaceableRemoved(placeable)
    local spec = self[SPEC_KEY]
    if spec == nil then
        return
    end

    spec.registryRemoveEventCount = spec.registryRemoveEventCount + 1
    self:removeConstructionProgressDisplayTarget(placeable, "PLACEABLE_REMOVED")
end

function CPD:onFinalizePlacement()
    local tracked = false
    for _, stand in ipairs(CPD.trackedStands) do
        if stand == self then
            tracked = true
            break
        end
    end
    if not tracked then
        table.insert(CPD.trackedStands, self)
    end

    -- Placeable:finalizePlacement() first calls PlaceableSystem:addPlaceable(),
    -- and only afterwards raises onFinalizePlacement. Therefore this stand has
    -- already received a stable uniqueId when we subscribe and build its list.
    self:subscribeConstructionProgressDisplayLifecycle()
    self:initializeConstructionProgressDisplayRegistry()

    local spec = self[SPEC_KEY]
    if spec ~= nil and spec.contentNode ~= nil and spec.contentNode ~= 0 and self.isClient then
        local alreadyRegistered = false
        for _, stand in ipairs(CPD.activeRenderStands) do
            if stand == self then
                alreadyRegistered = true
                break
            end
        end
        if not alreadyRegistered then
            table.insert(CPD.activeRenderStands, self)
            logInfo(
                "renderText3D stand registered standId=%s contentNode=%s activeCount=%d",
                tostring(getPlaceableUniqueId(self)),
                tostring(spec.contentNode),
                #CPD.activeRenderStands
            )
        end
    end

    local x, y, z = self:getConstructionProgressDisplaySearchPosition()
    local uniqueId = getPlaceableUniqueId(self)
    local ownerFarmId = self.getOwnerFarmId ~= nil and self:getOwnerFarmId() or nil

    local farmlandId = nil
    local landOwnerFarmId = nil
    if g_farmlandManager ~= nil then
        farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
        landOwnerFarmId = g_farmlandManager:getFarmlandOwner(farmlandId)
    end

    logInfo(
        "Finalized stand uniqueId=%s ownerFarmId=%s landFarmlandId=%s landOwnerFarmId=%s position=%.3f %.3f %.3f loadedFromSavegame=%s pickObjects=%d registryTargets=%d registryFullScans=%d",
        tostring(uniqueId),
        tostring(ownerFarmId),
        tostring(farmlandId),
        tostring(landOwnerFarmId),
        x,
        y,
        z,
        tostring(self.isLoadedFromSavegame == true),
        self.pickObjects ~= nil and #self.pickObjects or -1,
        spec ~= nil and #spec.targets or -1,
        spec ~= nil and spec.registryInitialScanCount or -1
    )
end



local function loadSavedTargetsFromPath(self, xmlFile, targetsPath, sourceLabel)
    local spec = self[SPEC_KEY]
    if spec == nil then return 0 end

    local loadedCount = 0
    for _, targetKey in xmlFile:iterator(targetsPath .. ".target") do
        local targetId = xmlFile:getValue(targetKey .. "#uniqueId")
        if targetId ~= nil and targetId ~= "" then
            targetId = tostring(targetId)

            local alreadyKnown = false
            for _, existingId in ipairs(spec.savedTargetIds) do
                if tostring(existingId) == targetId then alreadyKnown = true break end
            end
            if not alreadyKnown then
                table.insert(spec.savedTargetIds, targetId)
                loadedCount = loadedCount + 1
            end

            local snapshot = {}
            for _, materialKey in xmlFile:iterator(targetKey .. ".finalStorage.material") do
                local fillTypeName = xmlFile:getValue(materialKey .. "#fillType")
                local level = xmlFile:getValue(materialKey .. "#level", 0)
                local fillType = fillTypeName ~= nil and g_fillTypeManager ~= nil
                    and g_fillTypeManager:getFillTypeByName(fillTypeName) or nil
                if fillType ~= nil and level ~= nil then
                    snapshot[fillType.index] = math.max(0, tonumber(level) or 0)
                end
            end
            if next(snapshot) ~= nil then spec.savedTargetSnapshots[targetId] = snapshot end
        end
    end

    if loadedCount > 0 then
        logInfo("SAVEGAME TARGETS loaded standId=%s source=%s count=%d", tostring(getPlaceableUniqueId(self)), tostring(sourceLabel), loadedCount)
    end
    return loadedCount
end

function CPD:loadFromXMLFile(xmlFile, key)
    local spec = self[SPEC_KEY]
    if spec == nil then return end

    spec.savedTargetIds = {}
    spec.savedTargetSnapshots = {}
    spec.restoreExactTargetList = true

    local loaded = loadSavedTargetsFromPath(self, xmlFile, key .. ".targets", "current")
    if loaded == 0 then
        loadSavedTargetsFromPath(self, xmlFile, key .. ".constructionProgressDisplay.targets", "legacy-double-node")
    end

    local snapshotCount = 0
    for _ in pairs(spec.savedTargetSnapshots) do snapshotCount = snapshotCount + 1 end
    logInfo("SAVEGAME LOAD standId=%s key=%s savedTargets=%d snapshots=%d", tostring(getPlaceableUniqueId(self)), tostring(key), #spec.savedTargetIds, snapshotCount)
end

local function resolveAuthoritativeTargets(self, reason)
    local spec = self[SPEC_KEY]
    if spec == nil
        or not spec.mpRegistryAuthoritativeReceived
        or spec.savedTargetIds == nil then
        return 0, 0
    end

    local wanted = {}
    local pending = 0
    for _, savedId in ipairs(spec.savedTargetIds) do
        local id = tostring(savedId)
        wanted[id] = true
        if spec.targetByUniqueId[id] == nil then
            pending = pending + 1
        end
    end

    if pending == 0 then
        spec.mpPendingTargetCount = 0
        return 0, 0
    end

    local resolved = 0

    -- First choice: the actual synchronized node-object reference sent by the
    -- server. This avoids depending on client placeable load order.
    if spec.mpTargetObjectsByUniqueId ~= nil then
        for targetId, placeable in pairs(spec.mpTargetObjectsByUniqueId) do
            if wanted[targetId]
                and spec.targetByUniqueId[targetId] == nil
                and isCompatibleConstructible(placeable) then
                if self:addConstructionProgressDisplayTarget(placeable, reason or "MP_NODE_OBJECT") then
                    resolved = resolved + 1
                end
            end
        end
    end

    -- Fallback for a node object that was not registered yet when onReadStream
    -- ran. Retry by stable uniqueId after the rest of the map has loaded.
    if g_currentMission ~= nil
        and g_currentMission.placeableSystem ~= nil
        and g_currentMission.placeableSystem.placeables ~= nil then
        for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
            if isCompatibleConstructible(placeable) then
                local uniqueId = getPlaceableUniqueId(placeable)
                local targetId = uniqueId ~= nil and tostring(uniqueId) or nil
                if targetId ~= nil
                    and wanted[targetId]
                    and spec.targetByUniqueId[targetId] == nil then
                    if self:addConstructionProgressDisplayTarget(placeable, reason or "MP_DEFERRED_ID") then
                        resolved = resolved + 1
                    end
                end
            end
        end
    end

    pending = 0
    for _, savedId in ipairs(spec.savedTargetIds) do
        if spec.targetByUniqueId[tostring(savedId)] == nil then
            pending = pending + 1
        end
    end
    spec.mpPendingTargetCount = pending

    if resolved > 0 or pending ~= (spec.mpLastLoggedPendingTargetCount or -1) then
        spec.mpLastLoggedPendingTargetCount = pending
        logInfo(
            "MP target resolve standId=%s reason=%s resolvedNow=%d registry=%d authoritative=%d pending=%d",
            tostring(getPlaceableUniqueId(self)),
            tostring(reason),
            resolved,
            spec.targets ~= nil and #spec.targets or 0,
            #spec.savedTargetIds,
            pending
        )
    end

    if resolved > 0 then
        spec.reportDirty = true
        spec.reportForceRefresh = true
    end

    return resolved, pending
end

local function resetRegistryForAuthoritativeTargetList(self)
    local spec = self[SPEC_KEY]
    if spec == nil then
        return
    end

    if spec.targets ~= nil then
        for _, entry in ipairs(spec.targets) do
            detachTargetStorageListener(entry)
        end
    end

    spec.targets = {}
    spec.targetByUniqueId = {}
    spec.registryInitialized = false
    spec.selectedTargetUniqueId = nil
    spec.stagePageStart = nil
    spec.materialPageStart = 1
    self:initializeConstructionProgressDisplayRegistry()
end

function CPD:onWriteStream(streamId, connection)
    -- Persistent registry membership is server-authoritative. The selected tab
    -- is deliberately not written: every client owns its own local view.
    local spec = self[SPEC_KEY]
    local targets = spec ~= nil and spec.targets or {}
    streamWriteUInt16(streamId, math.min(#targets, 65535))

    local writeCount = math.min(#targets, 65535)
    for i = 1, writeCount do
        local entry = targets[i]
        -- Send the synchronized placeable itself as the primary reference and
        -- keep uniqueId as a stable fallback/persistence key.
        NetworkUtil.writeNodeObject(streamId, entry.placeable)
        streamWriteString(streamId, tostring(entry.uniqueId or ""))

        local snapshot = entry.finalStorageSnapshot
        local snapshotCount = 0
        if snapshot ~= nil then
            for _ in pairs(snapshot) do snapshotCount = snapshotCount + 1 end
        end
        snapshotCount = math.min(snapshotCount, 65535)
        streamWriteUInt16(streamId, snapshotCount)

        local written = 0
        if snapshot ~= nil then
            for fillTypeIndex, level in pairs(snapshot) do
                if written >= snapshotCount then break end
                streamWriteUIntN(streamId, fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
                streamWriteFloat32(streamId, level or 0)
                written = written + 1
            end
        end
    end

    logInfo(
        "MP registry sent standId=%s targets=%d connection=%s",
        tostring(getPlaceableUniqueId(self)),
        writeCount,
        tostring(connection)
    )
end

function CPD:onReadStream(streamId, connection)
    local spec = self[SPEC_KEY]
    if spec == nil then
        return
    end

    spec.savedTargetIds = {}
    spec.savedTargetSnapshots = {}
    spec.restoreExactTargetList = true
    spec.mpRegistryAuthoritativeReceived = true
    spec.mpTargetObjectsByUniqueId = {}

    local targetCount = streamReadUInt16(streamId)
    for _ = 1, targetCount do
        local targetPlaceable = NetworkUtil.readNodeObject(streamId)
        local targetId = tostring(streamReadString(streamId) or "")
        local snapshotCount = streamReadUInt16(streamId)
        local snapshot = {}
        for _ = 1, snapshotCount do
            local fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
            snapshot[fillTypeIndex] = streamReadFloat32(streamId)
        end

        if targetId ~= "" then
            table.insert(spec.savedTargetIds, targetId)
            spec.mpTargetObjectsByUniqueId[targetId] = targetPlaceable
            if next(snapshot) ~= nil then
                spec.savedTargetSnapshots[targetId] = snapshot
            end
        end
    end

    -- Placeable.postReadStream raises onReadStream after finalizePlacement(), so
    -- replace the client's provisional active-site scan with the exact server list.
    resetRegistryForAuthoritativeTargetList(self)
    local _, pending = resolveAuthoritativeTargets(self, "MP_STREAM")
    spec.reportDirty = true
    spec.reportForceRefresh = true

    logInfo(
        "MP registry received standId=%s authoritativeTargets=%d resolvedTargets=%d pendingTargets=%d",
        tostring(getPlaceableUniqueId(self)),
        #spec.savedTargetIds,
        spec.targets ~= nil and #spec.targets or 0,
        pending or 0
    )
end

function CPD:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self[SPEC_KEY]
    if spec == nil or spec.targets == nil then
        return
    end

    -- key is already ...placeable(...).constructionProgressDisplay.
    local baseKey = key .. ".targets"
    for index, entry in ipairs(spec.targets) do
        if entry ~= nil and entry.uniqueId ~= nil then
            local targetKey = string.format("%s.target(%d)", baseKey, index - 1)
            xmlFile:setValue(targetKey .. "#uniqueId", tostring(entry.uniqueId))

            if entry.finalStorageSnapshot ~= nil then
                local materialIndex = 0
                for fillTypeIndex, level in pairs(entry.finalStorageSnapshot) do
                    local fillType = g_fillTypeManager ~= nil
                        and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                        or nil
                    if fillType ~= nil and fillType.name ~= nil then
                        local materialKey = string.format(
                            "%s.finalStorage.material(%d)",
                            targetKey,
                            materialIndex
                        )
                        xmlFile:setValue(materialKey .. "#fillType", fillType.name)
                        xmlFile:setValue(materialKey .. "#level", level)
                        materialIndex = materialIndex + 1
                    end
                end
            end
        end
    end
    logInfo(
        "SAVEGAME SAVE standId=%s key=%s targets=%d",
        tostring(getPlaceableUniqueId(self)),
        tostring(key),
        #spec.targets
    )
end

function CPD:onDelete()
    local spec = self[SPEC_KEY]
    local uniqueId = getPlaceableUniqueId(self)

    if spec ~= nil and spec.targets ~= nil then
        for _, entry in ipairs(spec.targets) do
            detachTargetStorageListener(entry)
        end
    end

    for index = #CPD.activeRenderStands, 1, -1 do
        if CPD.activeRenderStands[index] == self then
            table.remove(CPD.activeRenderStands, index)
        end
    end
    for index = #CPD.trackedStands, 1, -1 do
        if CPD.trackedStands[index] == self then
            table.remove(CPD.trackedStands, index)
        end
    end
    logInfo(
        "Deleted stand uniqueId=%s registryTargets=%d registryFullScans=%d addEvents=%d removeEvents=%d",
        tostring(uniqueId),
        spec ~= nil and #spec.targets or -1,
        spec ~= nil and spec.registryInitialScanCount or -1,
        spec ~= nil and spec.registryAddEventCount or -1,
        spec ~= nil and spec.registryRemoveEventCount or -1
    )
end

function CPD:getConstructionProgressDisplaySearchPosition()
    local spec = self[SPEC_KEY]
    local node = spec ~= nil and spec.searchNode or self.rootNode

    if node == nil or node == 0 then
        if self.getPosition ~= nil then
            return self:getPosition()
        end
        return 0, 0, 0
    end

    return getWorldTranslation(node)
end

function CPD:getConstructionProgressDisplayTargets()
    local spec = self[SPEC_KEY]
    if spec == nil then
        return {}
    end
    return spec.targets
end

function CPD:getConstructionProgressDisplayTargetCount()
    local spec = self[SPEC_KEY]
    return spec ~= nil and #spec.targets or 0
end

-- Stage 06C official construction report renderer.
-- renderText3D is immediate-mode and must still be submitted every frame on
-- the client while the player is close enough to see it. Expensive construction
-- report data is cached and rebuilt no more often than the configured interval
-- (5 seconds by default). Storage callbacks only mark that cache stale.
local function getRenderPlayerWorldPosition()
    if g_currentMission ~= nil
        and g_currentMission.hud ~= nil
        and g_currentMission.hud.controlledVehicle ~= nil
        and g_currentMission.hud.controlledVehicle.rootNode ~= nil then
        return getWorldTranslation(g_currentMission.hud.controlledVehicle.rootNode)
    end

    if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
        return getWorldTranslation(g_localPlayer.rootNode)
    end

    return nil, nil, nil
end

local function renderPaperText(node, rx, ry, rz, x, y, size, text, alignment, bold, r, g, b, a, zOffset)
    if text == nil or text == "" then
        return
    end

    setTextAlignment(alignment or RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
    setTextBold(bold == true)
    setTextColor(r or 0.05, g or 0.055, b or 0.05, a or 1)

    local wx, wy, wz = localToWorld(node, x, y, zOffset or 0)
    renderText3D(wx, wy, wz, rx, ry, rz, size, text)
end

local function renderNoTargetReport(stand, spec, rx, ry, rz)
    local title = getLocalizedText("cpd_report_noTargetsTitle", stand.customEnvironment)
    local line1 = getLocalizedText("cpd_report_noTargetsLine1", stand.customEnvironment)
    local line2 = getLocalizedText("cpd_report_noTargetsLine2", stand.customEnvironment)

    renderPaperText(spec.contentNode, rx, ry, rz, 0, 0.14, 0.058, title, RenderText.ALIGN_CENTER, true)
    renderPaperText(spec.contentNode, rx, ry, rz, 0, 0.00, 0.038, line1, RenderText.ALIGN_CENTER, false)
    renderPaperText(spec.contentNode, rx, ry, rz, 0, -0.08, 0.038, line2, RenderText.ALIGN_CENTER, false)
end

local function fitStageName(text, maxChars)
    text = tostring(text or "")
    maxChars = maxChars or 34
    if utf8Strlen ~= nil and utf8Substr ~= nil then
        local len = utf8Strlen(text)
        if len > maxChars then
            return utf8Substr(text, 0, maxChars - 1) .. "…"
        end
    elseif #text > maxChars then
        return string.sub(text, 1, maxChars - 1) .. "…"
    end
    return text
end

local function updateReportPhoto(stand, spec, report)
    if stand == nil or not stand.isClient or spec == nil or spec.photoNode == nil
        or spec.photoNode == 0 or spec.photoMaterial == nil or spec.photoMaterial == 0 then
        return
    end

    local requestedFilename = report ~= nil and not report.noTarget and report.targetImageFilename or nil
    local useTargetImage = requestedFilename ~= nil
        and requestedFilename ~= ""
        and textureFileExists(requestedFilename)

    local effectiveFilename = useTargetImage and requestedFilename or spec.photoPlaceholderFilename
    if effectiveFilename == nil or effectiveFilename == "" or not textureFileExists(effectiveFilename) then
        return
    end

    if effectiveFilename == spec.photoCurrentFilename then
        spec.photoHasImage = useTargetImage
        return
    end

    -- photoDynamic is a material used only by photoNode.  Edit that same
    -- material in-place.  GIANTS documents that sharedEdit=true returns the
    -- same material id, so switching photos does not create/cache transient
    -- material entities that can later become invalid.
    local materialId = setMaterialDiffuseMapFromFile(
        spec.photoMaterial,
        effectiveFilename,
        false,
        true,
        true
    )

    if materialId ~= nil and materialId ~= 0 then
        spec.photoMaterial = materialId
        spec.photoCurrentFilename = effectiveFilename
        spec.photoHasImage = useTargetImage
        logInfo("Photo applied standId=%s targetId=%s file=%s targetImage=%s materialId=%s",
            tostring(getPlaceableUniqueId(stand)),
            tostring(report ~= nil and report.targetId or nil),
            tostring(effectiveFilename),
            tostring(useTargetImage),
            tostring(materialId))
    else
        spec.photoHasImage = false
        logInfo("Photo fallback standId=%s targetId=%s file=%s reason=MATERIAL_EDIT_FAILED",
            tostring(getPlaceableUniqueId(stand)),
            tostring(report ~= nil and report.targetId or nil),
            tostring(effectiveFilename))
    end
end

local function renderOfficialReport(stand, spec, report, rx, ry, rz)
    local node = spec.contentNode
    local env = stand.customEnvironment
    local darkR, darkG, darkB = 0.045, 0.050, 0.045
    local blueR, blueG, blueB = 0.070, 0.180, 0.300
    local whiteR, whiteG, whiteB = 0.95, 0.95, 0.92

    local statusText = getLocalizedText(
        report.isComplete and "cpd_report_statusComplete" or "cpd_report_statusActive",
        env
    )

    -- Physical paper tabs occupy the top edge.  Their backgrounds are I3D
    -- shapes; renderText3D only prints the page number onto each tab.
    if (report.targetCount or 0) > 1 and spec.documentTabs ~= nil then
        local first = spec.visibleTabStart or 1
        for slot = 1, math.min(#spec.documentTabs, report.targetCount or 0) do
            local actualIndex = first + slot - 1
            if actualIndex <= (report.targetCount or 0) then
                local tab = spec.documentTabs[slot]
                if tab ~= nil and tab.group ~= nil and getVisibility(tab.group) then
                    local tx, ty, tz = getTranslation(tab.group)
                    local selected = actualIndex == (report.targetIndex or 1)
                    renderPaperText(node, rx, ry, rz, tx, ty - 0.010, 0.0235,
                        tostring(actualIndex), RenderText.ALIGN_CENTER, true,
                        selected and whiteR or darkR,
                        selected and whiteG or darkG,
                        selected and whiteB or darkB,
                        1, 0.012)
                end
            end
        end
    end

    -- Header: current selected object only.  It is intentionally lower than
    -- before so the document tabs have a dedicated band above it.
    renderPaperText(node, rx, ry, rz, -0.80, 0.425, 0.045,
        getLocalizedText("cpd_report_title", env), RenderText.ALIGN_LEFT, true,
        blueR, blueG, blueB, 1)

    renderPaperText(node, rx, ry, rz, -0.80, 0.347, 0.031,
        string.format("%s:", getLocalizedText("cpd_report_object", env)),
        RenderText.ALIGN_LEFT, true, darkR, darkG, darkB, 1)
    renderPaperText(node, rx, ry, rz, -0.47, 0.347, 0.031,
        tostring(report.targetName), RenderText.ALIGN_LEFT, true, darkR, darkG, darkB, 1)

    renderPaperText(node, rx, ry, rz, -0.80, 0.297, 0.0285,
        string.format("%s: %s", getLocalizedText("cpd_report_status", env), statusText),
        RenderText.ALIGN_LEFT, false, darkR, darkG, darkB, 0.95)
    renderPaperText(node, rx, ry, rz, -0.80, 0.249, 0.0285,
        string.format("%s: %s", getLocalizedText("cpd_report_owner", env), tostring(report.responsible)),
        RenderText.ALIGN_LEFT, false, darkR, darkG, darkB, 0.95)
    renderPaperText(node, rx, ry, rz, -0.80, 0.201, 0.0295,
        string.format("%s: %.0f%%", getLocalizedText("cpd_report_progress", env), report.progressPercent or 0),
        RenderText.ALIGN_LEFT, true, blueR, blueG, blueB, 1)

    if not spec.photoHasImage then
        renderPaperText(node, rx, ry, rz, 1.020, 0.335, 0.022,
            getLocalizedText("cpd_report_imagePlaceholder", env), RenderText.ALIGN_CENTER, false,
            darkR, darkG, darkB, 0.42)
    end

    -- Dense construction-stage list. Percentages stay in the same right column.
    renderPaperText(node, rx, ry, rz, -1.190, 0.118, 0.0300,
        getLocalizedText("cpd_report_stages", env), RenderText.ALIGN_LEFT, true,
        whiteR, whiteG, whiteB, 1)
    if report.totalStages > MAX_VISIBLE_STAGES then
        local first = report.visibleStageStart or 1
        local last = math.min(report.totalStages, first + MAX_VISIBLE_STAGES - 1)
        renderPaperText(node, rx, ry, rz, -0.170, 0.118, 0.0185,
            string.format("%d–%d / %d   %s", first, last, report.totalStages, getLocalizedText("cpd_report_stagePageHint", env)),
            RenderText.ALIGN_RIGHT, false, whiteR, whiteG, whiteB, 0.94)
    end

    local stageTextYs = {0.054, 0.020, -0.014, -0.048, -0.082, -0.116, -0.150, -0.184, -0.218}
    for i = 1, MAX_VISIBLE_STAGES do
        local stage = report.visibleStages ~= nil and report.visibleStages[i] or nil
        if stage ~= nil then
            local label = stage.displayName
            if label == nil or label == "" then
                label = string.format("%s%d", getLocalizedText("cpd_report_stageNumberPrefix", env), stage.ordinal or 0)
            else
                label = string.format("%d. %s", stage.ordinal or 0, label)
            end
            label = fitStageName(label, 58)
            local percent = math.floor((stage.progress or 0) * 100 + 0.5)
            renderPaperText(node, rx, ry, rz, -1.145, stageTextYs[i], 0.0325,
                label, RenderText.ALIGN_LEFT, stage.ordinal == report.stageOrdinal,
                darkR, darkG, darkB, 1)
            renderPaperText(node, rx, ry, rz, -0.170, stageTextYs[i], 0.0300,
                string.format("%d%%", percent), RenderText.ALIGN_RIGHT, true,
                blueR, blueG, blueB, 1)
        end
    end

    -- Wider, denser six-column material table.
    renderPaperText(node, rx, ry, rz, -0.100, 0.118, 0.0300,
        getLocalizedText("cpd_report_materials", env), RenderText.ALIGN_LEFT, true,
        whiteR, whiteG, whiteB, 1)
    if report.materials ~= nil and #report.materials > MAX_VISIBLE_MATERIALS then
        local first = report.materialPageStart or 1
        local last = math.min(#report.materials, first + MAX_VISIBLE_MATERIALS - 1)
        renderPaperText(node, rx, ry, rz, 1.190, 0.118, 0.0155,
            string.format("%d–%d / %d   %s", first, last, #report.materials, getLocalizedText("cpd_report_materialPageHint", env)),
            RenderText.ALIGN_RIGHT, false, whiteR, whiteG, whiteB, 0.94)
    end

    local headerY = 0.076
    local rowYs = {0.043, 0.013, -0.017, -0.047, -0.077, -0.107, -0.137, -0.167, -0.197, -0.227, -0.257, -0.287, -0.317}
    local xName = -0.095
    local xConsumed = 0.555
    local xStored = 0.700
    local xTotal = 0.840
    local xRequired = 0.985
    local xBalance = 1.190

    renderPaperText(node, rx, ry, rz, xName, headerY, 0.0185,
        getLocalizedText("cpd_report_colMaterial", env), RenderText.ALIGN_LEFT, true,
        darkR, darkG, darkB, 0.95)
    renderPaperText(node, rx, ry, rz, xConsumed, headerY, 0.0170,
        getLocalizedText("cpd_report_colConsumed", env), RenderText.ALIGN_CENTER, true,
        darkR, darkG, darkB, 0.95)
    renderPaperText(node, rx, ry, rz, xStored, headerY, 0.0170,
        getLocalizedText("cpd_report_colStored", env), RenderText.ALIGN_CENTER, true,
        darkR, darkG, darkB, 0.95)
    renderPaperText(node, rx, ry, rz, xTotal, headerY, 0.0170,
        getLocalizedText("cpd_report_colSupplied", env), RenderText.ALIGN_CENTER, true,
        darkR, darkG, darkB, 0.95)
    renderPaperText(node, rx, ry, rz, xRequired, headerY, 0.0170,
        getLocalizedText("cpd_report_colRequired", env), RenderText.ALIGN_CENTER, true,
        darkR, darkG, darkB, 0.95)
    renderPaperText(node, rx, ry, rz, xBalance, headerY, 0.0170,
        getLocalizedText("cpd_report_colBalance", env), RenderText.ALIGN_RIGHT, true,
        darkR, darkG, darkB, 0.95)

    local visibleMaterials = report.visibleMaterials or report.materials or {}
    local rowCount = math.min(#visibleMaterials, MAX_VISIBLE_MATERIALS)
    for i = 1, rowCount do
        local material = visibleMaterials[i]
        local y = rowYs[i]
        renderPaperText(node, rx, ry, rz, xName, y, 0.0225,
            fitStageName(material.title, 34), RenderText.ALIGN_LEFT, true,
            darkR, darkG, darkB, 1)
        renderPaperText(node, rx, ry, rz, xConsumed, y, 0.0205,
            formatAmount(material.consumed, false), RenderText.ALIGN_CENTER, false,
            darkR, darkG, darkB, 0.95)
        renderPaperText(node, rx, ry, rz, xStored, y, 0.0205,
            formatAmount(material.stored, false), RenderText.ALIGN_CENTER, false,
            darkR, darkG, darkB, 0.95)
        renderPaperText(node, rx, ry, rz, xTotal, y, 0.0205,
            formatAmount(material.supplied, false), RenderText.ALIGN_CENTER, false,
            darkR, darkG, darkB, 0.95)
        renderPaperText(node, rx, ry, rz, xRequired, y, 0.0205,
            formatAmount(material.requiredRounded, false), RenderText.ALIGN_CENTER, false,
            darkR, darkG, darkB, 0.95)

        local br,bg,bb = darkR,darkG,darkB
        if (material.balance or 0) < -0.5 then
            br,bg,bb = 0.42,0.06,0.05
        elseif (material.balance or 0) > 0.5 then
            br,bg,bb = 0.05,0.28,0.10
        end
        renderPaperText(node, rx, ry, rz, xBalance, y, 0.0215,
            formatAmount(material.balance, true), RenderText.ALIGN_RIGHT, true,
            br,bg,bb,1)
    end
    renderPaperText(node, rx, ry, rz, -1.090, -0.430, 0.0205,
        getLocalizedText("cpd_report_autoNote", env), RenderText.ALIGN_LEFT, false,
        darkR, darkG, darkB, 0.60)
end

local function renderReportForStand(stand, dt)
    if stand == nil or stand.isDeleted or stand.markedForDeletion or not stand.isClient then
        return
    end

    local spec = stand[SPEC_KEY]
    if spec == nil or spec.contentNode == nil or spec.contentNode == 0 then
        return
    end

    local px, _, pz = getRenderPlayerWorldPosition()
    if px == nil then
        return
    end

    local nodeX, _, nodeZ = getWorldTranslation(spec.contentNode)
    local dx = px - nodeX
    local dz = pz - nodeZ
    local drawDistance = 30
    if dx * dx + dz * dz > drawDistance * drawDistance then
        return
    end

    if spec.mpRegistryAuthoritativeReceived and (spec.mpPendingTargetCount or 0) > 0 then
        spec.mpResolveTimerMs = (spec.mpResolveTimerMs or 0) + (dt or 0)
        if spec.mpResolveTimerMs >= MP_TARGET_RESOLVE_INTERVAL_MS then
            spec.mpResolveTimerMs = 0
            resolveAuthoritativeTargets(stand, "MP_DEFERRED")
        end
    end

    spec.reportRefreshTimerMs = (spec.reportRefreshTimerMs or 0) + (dt or 0)
    local refreshIntervalMs = spec.reportRefreshIntervalMs or DEFAULT_REPORT_REFRESH_INTERVAL_MS
    if spec.reportData == nil
        or spec.reportForceRefresh
        or (spec.reportDirty and spec.reportRefreshTimerMs >= refreshIntervalMs) then
        refreshReportData(stand)
    end

    local rx, ry, rz = getWorldRotation(spec.contentNode)
    local report = spec.reportData
    -- Texture probing/material edits are only needed when a new cached report
    -- was built, not on every immediate-mode text draw frame.
    if spec.photoReportData ~= report then
        updateReportPhoto(stand, spec, report)
        spec.photoReportData = report
    end
    if report == nil or report.noTarget then
        renderNoTargetReport(stand, spec, rx, ry, rz)
    else
        renderOfficialReport(stand, spec, report, rx, ry, rz)
    end

    -- Restore global RenderText state.
    setTextBold(false)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

function CPD:loadMap()
    self.interactionStand = nil
    self.nextConstructionActionEventId = nil
    self.nextStagePageActionEventId = nil
    self.nextMaterialPageActionEventId = nil
    self.actionRegistrationLogged = false
end

function CPD:deleteMap()
    if g_inputBinding ~= nil then
        local ids = {
            self.nextConstructionActionEventId,
            self.nextStagePageActionEventId,
            self.nextMaterialPageActionEventId
        }
        if PlayerInputComponent ~= nil and PlayerInputComponent.INPUT_CONTEXT_NAME ~= nil then
            g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)
            for _, eventId in pairs(ids) do
                if eventId ~= nil then
                    g_inputBinding:removeActionEvent(eventId)
                end
            end
            g_inputBinding:endActionEventsModification()
        else
            for _, eventId in pairs(ids) do
                if eventId ~= nil then
                    g_inputBinding:removeActionEvent(eventId)
                end
            end
        end
    end
    self.nextConstructionActionEventId = nil
    self.nextStagePageActionEventId = nil
    self.nextMaterialPageActionEventId = nil
    self.interactionStand = nil
end

function CPD:ensureNextConstructionActionEvent()
    if g_inputBinding == nil
        or InputAction == nil
        or PlayerInputComponent == nil
        or PlayerInputComponent.INPUT_CONTEXT_NAME == nil
        or g_localPlayer == nil
        or g_localPlayer.inputComponent == nil then
        return false
    end

    local function registerAction(action, callback, textKey, showText)
        if action == nil then
            return nil
        end
        g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)
        local ok, eventId = g_inputBinding:registerActionEvent(
            action, self, callback, false, true, false, true, nil, true
        )
        g_inputBinding:endActionEventsModification()
        if ok and eventId ~= nil then
            g_inputBinding:setActionEventActive(eventId, false)
            g_inputBinding:setActionEventTextVisibility(eventId, false)
            if textKey ~= nil then
                g_inputBinding:setActionEventText(eventId, g_i18n:getText(textKey))
            end
            if showText and g_inputBinding.setActionEventTextPriority ~= nil and GS_PRIO_HIGH ~= nil then
                g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_HIGH)
            end
            return eventId
        end
        return nil
    end

    if self.nextConstructionActionEventId == nil then
        self.nextConstructionActionEventId = registerAction(
            InputAction.CPD_NEXT_CONSTRUCTION,
            CPD.onNextConstructionAction,
            "input_CPD_NEXT_CONSTRUCTION",
            true
        )
    end
    if self.nextStagePageActionEventId == nil then
        self.nextStagePageActionEventId = registerAction(
            InputAction.CPD_NEXT_STAGE_PAGE,
            CPD.onNextStagePageAction,
            "input_CPD_NEXT_STAGE_PAGE",
            false
        )
    end
    if self.nextMaterialPageActionEventId == nil then
        self.nextMaterialPageActionEventId = registerAction(
            InputAction.CPD_NEXT_MATERIAL_PAGE,
            CPD.onNextMaterialPageAction,
            "input_CPD_NEXT_MATERIAL_PAGE",
            false
        )
    end

    local complete = self.nextConstructionActionEventId ~= nil
        and self.nextStagePageActionEventId ~= nil
        and self.nextMaterialPageActionEventId ~= nil

    if complete and not self.actionRegistrationLogged then
        self.actionRegistrationLogged = true
        local rBound = g_inputBinding.getActionEventsHasBinding ~= nil and g_inputBinding:getActionEventsHasBinding(self.nextConstructionActionEventId) or nil
        local lBound = g_inputBinding.getActionEventsHasBinding ~= nil and g_inputBinding:getActionEventsHasBinding(self.nextStagePageActionEventId) or nil
        local mBound = g_inputBinding.getActionEventsHasBinding ~= nil and g_inputBinding:getActionEventsHasBinding(self.nextMaterialPageActionEventId) or nil
        logInfo(
            "Input actions registered context=%s R=%s LMB=%s RMB=%s",
            tostring(PlayerInputComponent.INPUT_CONTEXT_NAME), tostring(rBound), tostring(lBound), tostring(mBound)
        )
    end

    return complete
end

function CPD:updateInteractionAction()
    local px, _, pz = getRenderPlayerWorldPosition()
    local nearest = nil
    local nearestDistSq = 16 -- 4 m interaction radius

    if px ~= nil then
        for _, stand in ipairs(CPD.activeRenderStands) do
            local spec = stand ~= nil and stand[SPEC_KEY] or nil
            if spec ~= nil and spec.interactionNode ~= nil and spec.interactionNode ~= 0 then
                local x, _, z = getWorldTranslation(spec.interactionNode)
                local dx = px - x
                local dz = pz - z
                local distSq = dx * dx + dz * dz
                if distSq <= nearestDistSq then
                    nearest = stand
                    nearestDistSq = distSq
                end
            end
        end
    end

    self.interactionStand = nearest
    local spec = nearest ~= nil and nearest[SPEC_KEY] or nil
    local report = spec ~= nil and spec.reportData or nil
    local canTarget = spec ~= nil and spec.targets ~= nil and #spec.targets > 1
    local canStagePage = report ~= nil and not report.noTarget and (report.totalStages or 0) > MAX_VISIBLE_STAGES
    local materialCount = report ~= nil and report.materials ~= nil and #report.materials or 0
    local canMaterialPage = report ~= nil and not report.noTarget and materialCount > MAX_VISIBLE_MATERIALS

    if self.nextConstructionActionEventId ~= nil and g_inputBinding ~= nil then
        g_inputBinding:setActionEventActive(self.nextConstructionActionEventId, canTarget)
        g_inputBinding:setActionEventTextVisibility(self.nextConstructionActionEventId, canTarget)
    end
    if self.nextStagePageActionEventId ~= nil and g_inputBinding ~= nil then
        g_inputBinding:setActionEventActive(self.nextStagePageActionEventId, canStagePage)
        g_inputBinding:setActionEventTextVisibility(self.nextStagePageActionEventId, false)
    end
    if self.nextMaterialPageActionEventId ~= nil and g_inputBinding ~= nil then
        g_inputBinding:setActionEventActive(self.nextMaterialPageActionEventId, canMaterialPage)
        g_inputBinding:setActionEventTextVisibility(self.nextMaterialPageActionEventId, false)
    end
end

function CPD:onNextConstructionAction(actionName, inputValue, callbackState, isAnalog)
    if self.interactionStand ~= nil then
        selectNextTarget(self.interactionStand)
    end
end

function CPD:onNextStagePageAction(actionName, inputValue, callbackState, isAnalog)
    if self.interactionStand ~= nil then
        cycleStagePage(self.interactionStand)
    end
end

function CPD:onNextMaterialPageAction(actionName, inputValue, callbackState, isAnalog)
    if self.interactionStand ~= nil then
        cycleMaterialPage(self.interactionStand)
    end
end

function CPD:update(dt)
    self:ensureNextConstructionActionEvent()
    self:updateInteractionAction()

    for index = #CPD.activeRenderStands, 1, -1 do
        local stand = CPD.activeRenderStands[index]
        if stand == nil or stand.isDeleted or stand.markedForDeletion then
            table.remove(CPD.activeRenderStands, index)
        else
            renderReportForStand(stand, dt)
        end
    end
end


-- Optional human-readable construction-stage name.
-- This extends the stock PlaceableConstructible XML schema for constructible
-- placeables without changing their runtime state machine. The exact attribute
-- requested by the project is StateName. The proven pattern is the same as
-- other map extensions that append custom XML paths to a stock specialization.
if PlaceableConstructible ~= nil
    and PlaceableConstructible.registerXMLPaths ~= nil
    and not PlaceableConstructible.cpdStateNameXMLHookInstalled then

    PlaceableConstructible.cpdStateNameXMLHookInstalled = true
    PlaceableConstructible.registerXMLPaths = Utils.appendedFunction(
        PlaceableConstructible.registerXMLPaths,
        function(schema, basePath)
            schema:register(
                XMLValueType.L10N_STRING,
                basePath .. ".constructible.stateMachine.states.state(?)#StateName",
                "Optional human-readable construction stage name for Construction Progress Display"
            )
        end
    )
    logInfo("Constructible StateName XML hook installed")
end

addModEventListener(CPD)
