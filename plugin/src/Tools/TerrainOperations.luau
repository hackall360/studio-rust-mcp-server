local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local Terrain = Workspace.Terrain

export type TerrainOperationsRequest = Types.TerrainOperationsRequest
export type TerrainOperationsResponse = Types.TerrainOperationsResponse
export type TerrainOperation = Types.TerrainOperation
export type TerrainFillBlockOperation = Types.TerrainFillBlockOperation
export type TerrainFillRegionOperation = Types.TerrainFillRegionOperation
export type TerrainReplaceMaterialOperation = Types.TerrainReplaceMaterialOperation
export type TerrainClearRegionOperation = Types.TerrainClearRegionOperation
export type TerrainConvertToTerrainOperation = Types.TerrainConvertToTerrainOperation
export type TerrainPivotPlacement = Types.TerrainPivotPlacement

local INT16_MIN = -32768
local INT16_MAX = 32767

local function isFiniteNumber(value: any): boolean
        return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function roundToInt(value: number): number
        if value >= 0 then
                return math.floor(value + 0.5)
        end
        return math.ceil(value - 0.5)
end

local function parseVector3(components: Types.Vector3Components?): (Vector3?, string?)
        if type(components) ~= "table" then
                return nil, "Expected an array of three numbers"
        end
        if #components < 3 then
                return nil, "Expected three numbers for vector components"
        end
        local values = table.create(3)
        for index = 1, 3 do
                local component = components[index]
                if not isFiniteNumber(component) then
                        return nil, string.format("Component %d must be a finite number", index)
                end
                values[index] = component
        end
        return Vector3.new(values[1], values[2], values[3]), nil
end

local function parseOptionalVector3(components: Types.Vector3Components?): (Vector3?, string?)
        if components == nil then
                return Vector3.new(0, 0, 0), nil
        end
        return parseVector3(components)
end

local function parseVector3int16(components: Types.RegionCornerComponents?): (Vector3int16?, string?)
        if type(components) ~= "table" then
                return nil, "Expected an array of three integers"
        end
        if #components < 3 then
                return nil, "Expected three integers for region corner"
        end
        local values = table.create(3)
        for index = 1, 3 do
                local component = components[index]
                if not isFiniteNumber(component) then
                        return nil, string.format("Corner component %d must be a finite number", index)
                end
                local rounded = roundToInt(component)
                values[index] = math.clamp(rounded, INT16_MIN, INT16_MAX)
        end
        return Vector3int16.new(values[1], values[2], values[3]), nil
end

local function parseCFrame(components: Types.CFrameComponents?): (CFrame?, string?)
        if type(components) ~= "table" then
                return nil, "Expected cframeComponents to be an array of 12 numbers"
        end
        if #components < 12 then
                return nil, "cframeComponents must contain 12 numbers"
        end
        local values = table.create(12)
        for index = 1, 12 do
                local component = components[index]
                if not isFiniteNumber(component) then
                        return nil, string.format("CFrame component %d must be a finite number", index)
                end
                values[index] = component
        end
        return CFrame.new(table.unpack(values, 1, 12)), nil
end

local function vectorToArray(vector: Vector3): { number }
        return { vector.X, vector.Y, vector.Z }
end

local function vector3int16ToArray(vector: Vector3int16): { number }
        return { vector.X, vector.Y, vector.Z }
end

local function cframeToArray(cf: CFrame): { number }
        local x, y, z,
                r00, r01, r02,
                r10, r11, r12,
                r20, r21, r22 = cf:GetComponents()
        return { x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 }
end

local function parseOccupancy(value: any): number?
        if typeof(value) ~= "number" then
                return nil
        end
        if not isFiniteNumber(value) then
                return nil
        end
        return math.clamp(value, 0, 1)
end

local function parseResolution(value: any, defaultValue: number): number
        if typeof(value) ~= "number" then
                return defaultValue
        end
        if not isFiniteNumber(value) then
                return defaultValue
        end
        local rounded = roundToInt(value)
        return math.max(1, rounded)
end

local function resolveMaterial(materialName: string?): (Enum.Material?, string?)
        if type(materialName) ~= "string" or materialName == "" then
                return nil, "A material name is required"
        end

        local candidate = Enum.Material[materialName]
        if candidate then
                return candidate, nil
        end

        local lower = string.lower(materialName)
        for _, item in Enum.Material:GetEnumItems() do
                if string.lower(item.Name) == lower then
                        return item, nil
                end
        end

        return nil, string.format("Unknown material '%s'", materialName)
end

type PivotContext = {
        cframe: CFrame,
        position: Vector3,
        cell: Vector3int16?,
}

local function resolvePivotPlacement(pivot: TerrainPivotPlacement?): (PivotContext?, string?)
        if type(pivot) ~= "table" then
                return nil, nil
        end

        local mode = pivot.mode or "active_camera"
        if mode ~= "active_camera" then
                return nil, string.format("Unsupported pivot mode '%s'", tostring(mode))
        end

        local camera = Workspace.CurrentCamera
        if not camera then
                return nil, "Pivot placement requested but no active camera is available"
        end

        local offset, offsetError = parseOptionalVector3(pivot.offset)
        if not offset then
                return nil, string.format("Invalid pivot offset: %s", offsetError)
        end

        local offsetCFrame = camera.CFrame
        if offset.Magnitude > 0 then
                offsetCFrame = offsetCFrame * CFrame.new(offset.X, offset.Y, offset.Z)
        end

        return {
                cframe = offsetCFrame,
                position = offsetCFrame.Position,
                cell = nil,
        }, nil
end

local function ensurePivotCell(context: PivotContext): Vector3int16
        if context.cell then
                return context.cell
        end

        local x, y, z = Terrain:WorldToCellPreferSolid(context.position)
        context.cell = Vector3int16.new(x, y, z)
        return context.cell
end

local function applyPivotToCFrame(baseCFrame: CFrame, context: PivotContext?, relative: boolean): CFrame
        if not relative or not context then
                return baseCFrame
        end

        local components = { baseCFrame:GetComponents() }
        local translation = Vector3.new(components[1], components[2], components[3])
        local targetPosition = context.position + translation
        components[1] = targetPosition.X
        components[2] = targetPosition.Y
        components[3] = targetPosition.Z
        return CFrame.new(table.unpack(components, 1, 12))
end

local function applyPivotToCorner(corner: Vector3int16, context: PivotContext?, relative: boolean): Vector3int16
        if not relative or not context then
                return corner
        end

        local pivotCell = ensurePivotCell(context)
        return Vector3int16.new(
                pivotCell.X + corner.X,
                pivotCell.Y + corner.Y,
                pivotCell.Z + corner.Z
        )
end

local function handleFillBlock(operation: TerrainFillBlockOperation, pivotContext: PivotContext?, pivotError: string?): (boolean, string?, { [string]: any }?, boolean)
        local cframe, cframeError = parseCFrame(operation.cframeComponents)
        if not cframe then
                return false, cframeError, nil, false
        end

        local pivotRelative = operation.pivotRelative == true
        if pivotRelative and not pivotContext then
                return false, pivotError or "fill_block requested pivotRelative but no pivot was resolved", nil, false
        end

        local resolvedCFrame = applyPivotToCFrame(cframe, pivotContext, pivotRelative)

        local size, sizeError = parseVector3(operation.size)
        if not size then
                return false, sizeError, nil, false
        end

        local material, materialError = resolveMaterial(operation.material)
        if not material then
                return false, materialError, nil, false
        end

        local occupancy = parseOccupancy(operation.occupancy)

        local ok, err = pcall(function()
                if occupancy ~= nil then
                        Terrain:FillBlock(resolvedCFrame, size, material, occupancy)
                else
                        Terrain:FillBlock(resolvedCFrame, size, material)
                end
        end)

        local details = {
                cframeComponents = cframeToArray(resolvedCFrame),
                size = vectorToArray(size),
                material = material.Name,
        }
        if occupancy ~= nil then
                details.occupancy = occupancy
        end

        if not ok then
                return false, string.format("FillBlock failed: %s", tostring(err)), details, false
        end

        local message = string.format("Filled block using %s", material.Name)
        return true, message, details, true
end

local function handleFillRegion(operation: TerrainFillRegionOperation, pivotContext: PivotContext?, pivotError: string?): (boolean, string?, { [string]: any }?, boolean)
        local cornerMin, minError = parseVector3int16(operation.cornerMin)
        if not cornerMin then
                return false, minError, nil, false
        end

        local cornerMax, maxError = parseVector3int16(operation.cornerMax)
        if not cornerMax then
                return false, maxError, nil, false
        end

        local pivotRelative = operation.pivotRelative == true
        if pivotRelative and not pivotContext then
                return false, pivotError or "fill_region requested pivotRelative but no pivot was resolved", nil, false
        end

        local resolvedMin = applyPivotToCorner(cornerMin, pivotContext, pivotRelative)
        local resolvedMax = applyPivotToCorner(cornerMax, pivotContext, pivotRelative)
        local resolution = parseResolution(operation.resolution, 4)

        local material, materialError = resolveMaterial(operation.material)
        if not material then
                return false, materialError, nil, false
        end

        local region = Region3int16.new(resolvedMin, resolvedMax)
        local ok, err = pcall(function()
                Terrain:FillRegion(region, resolution, material)
        end)

        local details = {
                cornerMin = vector3int16ToArray(resolvedMin),
                cornerMax = vector3int16ToArray(resolvedMax),
                resolution = resolution,
                material = material.Name,
        }

        if not ok then
                return false, string.format("FillRegion failed: %s", tostring(err)), details, false
        end

        local message = string.format("Filled region using %s", material.Name)
        return true, message, details, true
end

local function handleReplaceMaterial(operation: TerrainReplaceMaterialOperation, pivotContext: PivotContext?, pivotError: string?): (boolean, string?, { [string]: any }?, boolean)
        local cornerMin, minError = parseVector3int16(operation.cornerMin)
        if not cornerMin then
                return false, minError, nil, false
        end

        local cornerMax, maxError = parseVector3int16(operation.cornerMax)
        if not cornerMax then
                return false, maxError, nil, false
        end

        local pivotRelative = operation.pivotRelative == true
        if pivotRelative and not pivotContext then
                return false, pivotError or "replace_material requested pivotRelative but no pivot was resolved", nil, false
        end

        local resolvedMin = applyPivotToCorner(cornerMin, pivotContext, pivotRelative)
        local resolvedMax = applyPivotToCorner(cornerMax, pivotContext, pivotRelative)
        local resolution = parseResolution(operation.resolution, 4)

        local sourceMaterial, sourceError = resolveMaterial(operation.sourceMaterial)
        if not sourceMaterial then
                return false, sourceError, nil, false
        end

        local targetMaterial, targetError = resolveMaterial(operation.targetMaterial)
        if not targetMaterial then
                return false, targetError, nil, false
        end

        local region = Region3int16.new(resolvedMin, resolvedMax)
        local ok, err = pcall(function()
                Terrain:ReplaceMaterial(region, resolution, sourceMaterial, targetMaterial)
        end)

        local details = {
                cornerMin = vector3int16ToArray(resolvedMin),
                cornerMax = vector3int16ToArray(resolvedMax),
                resolution = resolution,
                sourceMaterial = sourceMaterial.Name,
                targetMaterial = targetMaterial.Name,
        }

        if not ok then
                return false, string.format("ReplaceMaterial failed: %s", tostring(err)), details, false
        end

        local message = string.format("Replaced %s with %s", sourceMaterial.Name, targetMaterial.Name)
        return true, message, details, true
end

local function handleClearRegion(operation: TerrainClearRegionOperation, pivotContext: PivotContext?, pivotError: string?): (boolean, string?, { [string]: any }?, boolean)
        local hasRegion = operation.cornerMin ~= nil or operation.cornerMax ~= nil
        if hasRegion and (operation.cornerMin == nil or operation.cornerMax == nil) then
                return false, "clear_region requires both cornerMin and cornerMax when specifying a region", nil, false
        end

        local pivotRelative = operation.pivotRelative == true
        if pivotRelative and not pivotContext then
                return false, pivotError or "clear_region requested pivotRelative but no pivot was resolved", nil, false
        end

        if hasRegion then
                local cornerMin, minError = parseVector3int16(operation.cornerMin)
                if not cornerMin then
                        return false, minError, nil, false
                end

                local cornerMax, maxError = parseVector3int16(operation.cornerMax)
                if not cornerMax then
                        return false, maxError, nil, false
                end

                local resolvedMin = applyPivotToCorner(cornerMin, pivotContext, pivotRelative)
                local resolvedMax = applyPivotToCorner(cornerMax, pivotContext, pivotRelative)
                local resolution = parseResolution(operation.resolution, 4)

                if typeof(Terrain.ClearRegion) ~= "function" then
                        return false, "Terrain:ClearRegion is unavailable in this Studio build", nil, false
                end

                local region = Region3int16.new(resolvedMin, resolvedMax)
                local ok, err = pcall(function()
                        Terrain:ClearRegion(region, resolution)
                end)

                local details = {
                        cornerMin = vector3int16ToArray(resolvedMin),
                        cornerMax = vector3int16ToArray(resolvedMax),
                        resolution = resolution,
                        scope = "region",
                }

                if not ok then
                        return false, string.format("ClearRegion failed: %s", tostring(err)), details, false
                end

                return true, "Cleared terrain region", details, true
        end

        local ok, err = pcall(function()
                Terrain:Clear()
        end)

        if not ok then
                return false, string.format("Clear failed: %s", tostring(err)), { scope = "all" }, false
        end

        return true, "Cleared all terrain", { scope = "all" }, true
end

local function normalisePath(path: Types.InstancePath): { string }
        local normalised = {}
        if type(path) ~= "table" then
                return normalised
        end

        for _, segment in path do
                if typeof(segment) == "string" and segment ~= "" and segment ~= "game" and segment ~= "DataModel" then
                        if segment ~= "Workspace" and segment ~= "workspace" then
                                table.insert(normalised, segment)
                        end
                end
        end

        return normalised
end

local function resolveInstance(path: Types.InstancePath): (Instance?, string?, { string }?)
        local normalised = normalisePath(path)
        if #normalised == 0 then
                return Workspace, nil, normalised
        end

        local current: Instance = Workspace
        for _, segment in normalised do
                local child = current:FindFirstChild(segment)
                if not child then
                        return nil, string.format("Unable to find '%s' under %s", segment, current:GetFullName()), normalised
                end
                current = child
        end

        return current, nil, normalised
end

local function convertPartToTerrain(part: BasePart, resolution: number, material: Enum.Material?): (boolean, string?)
        local errors = {}

        if typeof(Workspace.ConvertToTerrain) == "function" then
                local ok, err = pcall(function()
                        if material then
                                Workspace:ConvertToTerrain(part, resolution, material)
                        else
                                Workspace:ConvertToTerrain(part, resolution)
                        end
                end)
                if ok then
                        return true, nil
                end
                table.insert(errors, string.format("ConvertToTerrain: %s", tostring(err)))
        end

        if typeof(Workspace.ConvertPartToTerrain) == "function" then
                local ok, err = pcall(function()
                        if material then
                                Workspace:ConvertPartToTerrain(part, resolution, material)
                        else
                                Workspace:ConvertPartToTerrain(part, resolution)
                        end
                end)
                if ok then
                        return true, nil
                end
                table.insert(errors, string.format("ConvertPartToTerrain: %s", tostring(err)))

                if material then
                        local okNoMaterial, errNoMaterial = pcall(function()
                                Workspace:ConvertPartToTerrain(part, resolution)
                        end)
                        if okNoMaterial then
                                return true, nil
                        end
                        table.insert(errors, string.format("ConvertPartToTerrain(no material): %s", tostring(errNoMaterial)))
                end
        end

        if #errors == 0 then
                return false, "Workspace does not expose terrain conversion APIs in this Studio build"
        end

        return false, table.concat(errors, "; ")
end

local function handleConvertToTerrain(operation: TerrainConvertToTerrainOperation): (boolean, string?, { [string]: any }?, boolean)
        local paths = operation.paths
        if type(paths) ~= "table" or #paths == 0 then
                return false, "convert_to_terrain requires at least one instance path", nil, false
        end

        local resolution = parseResolution(operation.resolution, 4)
        local material: Enum.Material? = nil
        if operation.targetMaterial ~= nil then
                local resolvedMaterial, materialError = resolveMaterial(operation.targetMaterial)
                if not resolvedMaterial then
                        return false, materialError, nil, false
                end
                material = resolvedMaterial
        end

        local converted = {}
        local failures = {}
        local convertedCount = 0

        for _, path in paths do
                local instance, err, normalised = resolveInstance(path)
                if not instance then
                        table.insert(failures, err or "Unable to resolve instance path")
                elseif not instance:IsA("BasePart") then
                        table.insert(failures, string.format("%s is a %s (expected BasePart)", instance:GetFullName(), instance.ClassName))
                else
                        local success, convertError = convertPartToTerrain(instance :: BasePart, resolution, material)
                        if success then
                                convertedCount += 1
                                table.insert(converted, normalised)
                        else
                                table.insert(failures, convertError or string.format("Failed to convert %s", instance:GetFullName()))
                        end
                end
        end

        local details: { [string]: any } = {
                resolution = resolution,
                converted = converted,
        }
        if material then
                details.material = material.Name
        end
        if #failures > 0 then
                details.failures = failures
        end

        if convertedCount == 0 then
                return false, "No parts were converted to terrain", details, false
        end

        local message = string.format("Converted %d/%d parts to terrain", convertedCount, #paths)
        return true, message, details, true
end

local OPERATION_HANDLERS: { [string]: (TerrainOperation, PivotContext?, string?) -> (boolean, string?, { [string]: any }?, boolean) } = {
        fill_block = function(operation, pivotContext, pivotError)
                return handleFillBlock(operation :: TerrainFillBlockOperation, pivotContext, pivotError)
        end,
        fill_region = function(operation, pivotContext, pivotError)
                return handleFillRegion(operation :: TerrainFillRegionOperation, pivotContext, pivotError)
        end,
        replace_material = function(operation, pivotContext, pivotError)
                return handleReplaceMaterial(operation :: TerrainReplaceMaterialOperation, pivotContext, pivotError)
        end,
        clear_region = function(operation, pivotContext, pivotError)
                return handleClearRegion(operation :: TerrainClearRegionOperation, pivotContext, pivotError)
        end,
        convert_to_terrain = function(operation, _pivotContext, _pivotError)
                return handleConvertToTerrain(operation :: TerrainConvertToTerrainOperation)
        end,
}

local function buildSummary(total: number, successes: number, failures: number, pivotError: string?, pivotContext: PivotContext?): string
        local summary = string.format("Processed %d terrain operations (%d succeeded, %d failed)", total, successes, failures)
        if pivotError and not pivotContext then
                summary ..= " - " .. pivotError
        end
        return summary
end

local function handleTerrainOperations(args: Types.ToolArgs): string?
        if args.tool ~= "TerrainOperations" then
                return nil
        end

        local params = args.params :: TerrainOperationsRequest
        if type(params) ~= "table" then
                error("Missing params in TerrainOperations payload")
        end

        local operations = params.operations
        if type(operations) ~= "table" or #operations == 0 then
                error("terrain_operations requires at least one operation")
        end

        local pivotContext, pivotError = resolvePivotPlacement(params.pivot)

        local results = table.create(#operations)
        local successes = 0
        local writeOccurred = false

        for index, operation in operations do
                local opName = tostring(operation.operation)
                local handler = OPERATION_HANDLERS[opName]

                if not handler then
                        results[index] = {
                                index = index,
                                operation = opName,
                                success = false,
                                message = string.format("Unsupported terrain operation '%s'", opName),
                        }
                else
                        local success, message, details, wrote = handler(operation, pivotContext, pivotError)
                        if success then
                                successes += 1
                        end
                        if wrote then
                                writeOccurred = true
                        end

                        local result: Types.TerrainOperationResult = {
                                index = index,
                                operation = opName,
                                success = success,
                        }
                        if message then
                                result.message = message
                        end
                        if details and next(details) ~= nil then
                                result.details = details
                        end

                        results[index] = result
                end
        end

        local summary = buildSummary(#operations, successes, #operations - successes, pivotError, pivotContext)
        local response: TerrainOperationsResponse = {
                results = results,
                summary = summary,
                writeOccurred = writeOccurred,
        }

        return HttpService:JSONEncode(response)
end

return handleTerrainOperations :: Types.ToolFunction
