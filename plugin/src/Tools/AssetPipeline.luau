local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")
local InsertService = game:GetService("InsertService")

local okAssetService, AssetService = pcall(function()
        return game:GetService("AssetService")
end)

if not okAssetService then
        AssetService = nil
end

local function clamp(value: number, minValue: number, maxValue: number): number
        if value ~= value then
                return minValue
        end
        if value < minValue then
                return minValue
        end
        if value > maxValue then
                return maxValue
        end
        return value
end

local function jsonEncode(payload: Types.AssetPipelineResponse): string
        return HttpService:JSONEncode(payload)
end

local function normalisePath(path: Types.InstancePath?): { string }
        local normalised = {}
        if type(path) ~= "table" then
                return normalised
        end

        for _, segment in path do
                if type(segment) == "string" and segment ~= "" and segment ~= "game" and segment ~= "DataModel" then
                        table.insert(normalised, segment)
                end
        end

        return normalised
end

local function resolveInstance(path: Types.InstancePath?): (Instance?, string?)
        local normalised = normalisePath(path)
        local current: Instance = game

        if #normalised == 0 then
                return current, nil
        end

        for index, segment in normalised do
                local nextInstance = current:FindFirstChild(segment)
                if not nextInstance then
                        local parentName = if index == 1 then "game" else current:GetFullName()
                        return nil, string.format("Unable to find '%s' under %s", segment, parentName)
                end
                current = nextInstance
        end

        return current, nil
end

local function describeInstancePath(instance: Instance): { string }
        local segments = {}
        local current: Instance? = instance

        while current and current ~= game do
                table.insert(segments, 1, current.Name)
                current = current.Parent
        end

        table.insert(segments, 1, "game")

        return segments
end

local function collapseObjectsIntoContainer(objects: { Instance }): Instance?
        local isPhysical = false
        for _, object in objects do
                if object:IsA("PVInstance") then
                        isPhysical = true
                        break
                end
        end

        if isPhysical then
                local model = Instance.new("Model")
                for _, object in objects do
                        object.Parent = model
                end
                return model
        end

        if #objects > 1 then
                        local folder = Instance.new("Folder")
                        for _, object in objects do
                                object.Parent = folder
                        end
                        return folder
        end

        return objects[1]
end

local function loadAssetVersion(assetVersionId: number): (Instance?, string?)
        local success, result = pcall(function()
                return InsertService:LoadAssetVersion(assetVersionId)
        end)

        if not success then
                return nil, string.format("Failed to load asset version %s: %s", tostring(assetVersionId), tostring(result))
        end

        if typeof(result) == "Instance" then
                return result, nil
        elseif type(result) == "table" then
                local objects = {}
                for _, item in result do
                        if typeof(item) == "Instance" then
                                table.insert(objects, item)
                        end
                end
                if #objects > 0 then
                        return collapseObjectsIntoContainer(objects), nil
                end
        end

        return nil, "Asset version did not return any instances"
end

local function loadLocalAsset(path: string): (Instance?, string?)
        local success, result = pcall(function()
                return InsertService:LoadLocalAsset(path)
        end)

        if not success then
                return nil, string.format("Failed to load local asset '%s': %s", path, tostring(result))
        end

        if typeof(result) == "Instance" then
                return result, nil
        elseif type(result) == "table" then
                local objects = {}
                for _, item in result do
                        if typeof(item) == "Instance" then
                                table.insert(objects, item)
                        end
                end
                if #objects > 0 then
                        return collapseObjectsIntoContainer(objects), nil
                end
        end

        return nil, string.format("Local asset '%s' did not contain any instances", path)
end

local function resolveCollisionStrategy(operationStrategy: Types.AssetCollisionStrategy?, defaultStrategy: Types.AssetCollisionStrategy?): Types.AssetCollisionStrategy
        if operationStrategy == "overwrite" or operationStrategy == "skip" then
                return operationStrategy
        end

        if defaultStrategy == "overwrite" or defaultStrategy == "skip" then
                return defaultStrategy
        end

        return "rename"
end

local function resolveNameCollision(parent: Instance, instance: Instance, desiredName: string?, strategy: Types.AssetCollisionStrategy): (string?, { [string]: any }?)
        local baseName = if type(desiredName) == "string" and desiredName ~= "" then desiredName else instance.Name
        if baseName == "" then
                baseName = instance.ClassName
        end

        if strategy == "overwrite" then
                local existing = parent:FindFirstChild(baseName)
                if existing then
                        existing:Destroy()
                        return baseName, { overwritten = true, previousInstanceClass = existing.ClassName }
                end
                return baseName, nil
        elseif strategy == "skip" then
                if parent:FindFirstChild(baseName) then
                        return nil, { skipped = true, conflictedName = baseName }
                end
                return baseName, nil
        end

        local candidate = baseName
        local suffix = 1
        while parent:FindFirstChild(candidate) do
                candidate = string.format("%s (%d)", baseName, suffix)
                suffix += 1
        end

        if candidate ~= baseName then
                return candidate, { renamedFrom = baseName }
        end

        return candidate, nil
end

local function applyPlacement(instance: Instance, placement: Types.AssetPlacementOptions?): { [string]: any }?
        if type(placement) ~= "table" then
                return nil
        end

        local mode = placement.mode or "preserve"
        local pvTarget: Instance? = if instance:IsA("Model") then instance elseif instance:IsA("PVInstance") then instance else nil
        if not pvTarget then
                return nil
        end

        local applied: { [string]: any } = { mode = mode }
        if mode == "camera" then
                local camera = workspace.CurrentCamera
                if camera then
                        local origin = camera.CFrame.Position
                        local lookVector = camera.CFrame.LookVector
                        local target = CFrame.lookAt(origin + lookVector * 20, origin + lookVector * 21)
                        if pvTarget:IsA("Model") then
                                (pvTarget :: Model):PivotTo(target)
                        else
                                (pvTarget :: PVInstance).CFrame = target
                        end
                end
        elseif mode == "origin" then
                local target = CFrame.new(0, 0, 0)
                if pvTarget:IsA("Model") then
                        (pvTarget :: Model):PivotTo(target)
                else
                        (pvTarget :: PVInstance).CFrame = target
                end
        elseif mode == "custom_cframe" then
                local components = placement.cframeComponents
                if type(components) == "table" and #components == 12 then
                        local target = CFrame.new(table.unpack(components))
                        if pvTarget:IsA("Model") then
                                (pvTarget :: Model):PivotTo(target)
                        else
                                (pvTarget :: PVInstance).CFrame = target
                        end
                        applied.components = components
                end
        end

        return applied
end

local function publishInstanceAsPackage(instance: Instance, request: Types.PackagePublishRequest): (boolean, string?, { [string]: any }?)
        if not AssetService then
                return false, "AssetService is unavailable in this Studio session", nil
        end

        if type(request.packageName) ~= "string" or request.packageName == "" then
                return false, "Package publishing requires a packageName value", nil
        end

        local ok, upload = pcall(function()
                return AssetService:CreatePackageUpload(instance)
        end)

        if not ok or typeof(upload) ~= "Instance" then
                return false, string.format("Failed to initialise package upload: %s", tostring(upload)), nil
        end

        local warnings = {}

        local function safeAssign(name: string, callback)
                local success, err = pcall(callback)
                if not success then
                        table.insert(warnings, string.format("Unable to set %s: %s", name, tostring(err)))
                end
        end

        if request.packageName then
                safeAssign("packageName", function()
                        upload.Name = request.packageName
                end)
        end

        if request.description then
                safeAssign("description", function()
                        upload.Description = request.description
                end)
        end

        if request.tags then
                safeAssign("tags", function()
                        upload.Tags = request.tags
                end)
        end

        if request.groupId then
                safeAssign("groupId", function()
                        upload.GroupId = request.groupId
                end)
        end

        if request.allowOverwrite ~= nil then
                safeAssign("allowOverwrite", function()
                        upload.AllowPackageOverwrite = request.allowOverwrite
                end)
        end

        if request.allowComments ~= nil then
                safeAssign("allowComments", function()
                        upload.AllowComments = request.allowComments
                end)
        end

        local publishSuccess, result = pcall(function()
                if upload.PublishAsync then
                        return upload:PublishAsync()
                elseif upload.Publish then
                        return upload:Publish()
                end
                return upload
        end)

        if not publishSuccess then
                return false, string.format("Failed to publish package: %s", tostring(result)), nil
        end

        local metadata: { [string]: any } = {}
        if type(result) == "table" then
                for key, value in result do
                        metadata[key] = value
                end
        end

        if upload.AssetId and metadata.packageId == nil then
                metadata.packageId = upload.AssetId
        end
        if upload.AssetVersionId and metadata.packageVersionId == nil then
                metadata.packageVersionId = upload.AssetVersionId
        end

        if #warnings > 0 then
                metadata.warnings = warnings
        end

        metadata.instancePath = describeInstancePath(instance)

        return true, nil, metadata
end

local function resolveTargetParent(operationPath: Types.InstancePath?, defaults: Types.AssetPipelineRequest): (Instance, { [string]: any }?)
        local effectivePath = operationPath or defaults.defaultParentPath
        if not effectivePath then
                return workspace, nil
        end

        local parent, err = resolveInstance(effectivePath)
        if parent then
                return parent, nil
        end

        return workspace, { warning = err, fallbackParent = workspace:GetFullName(), requestedPath = effectivePath }
end

local function processSearchMarketplace(operation: Types.AssetPipelineSearchMarketplace): Types.AssetPipelineOperationResult
        if type(operation.query) ~= "string" or operation.query == "" then
                return {
                        action = "search_marketplace",
                        success = false,
                        status = "error",
                        message = "Marketplace search requires a non-empty query",
                }
        end

        local limit = clamp(math.floor(operation.limit or 10), 1, 50)
        local success, response = pcall(function()
                return InsertService:GetFreeModels(operation.query, 0)
        end)

        if not success then
                return {
                        action = "search_marketplace",
                        success = false,
                        status = "error",
                        message = string.format("Failed to search marketplace: %s", tostring(response)),
                }
        end

        local details = {
                query = operation.query,
                results = {},
        }

        local count = 0
        if type(response) == "table" and response[1] and type(response[1]) == "table" and response[1].Results then
                for _, entry in response[1].Results do
                        if type(entry) == "table" then
                                table.insert(details.results, {
                                        name = entry.Name,
                                        assetId = entry.AssetId,
                                        assetVersionId = entry.AssetVersionId,
                                        creatorName = entry.CreatorName,
                                })
                                count += 1
                                if count >= limit then
                                        break
                                end
                        end
                end
        end

        return {
                action = "search_marketplace",
                success = true,
                status = "completed",
                message = string.format("Retrieved %d marketplace results", #details.results),
                details = details,
        }
end

local function processInsertOrImport(
        defaults: Types.AssetPipelineRequest,
        operation: Types.AssetPipelineInsertAssetVersion | Types.AssetPipelineImportRbxm,
        loadFn: () -> (Instance?, string?),
        sourceDetails: { [string]: any }
): Types.AssetPipelineOperationResult
        local parent, parentWarning = resolveTargetParent(operation.targetParentPath, defaults)
        local collisionStrategy = resolveCollisionStrategy(operation.collisionStrategy, defaults.defaultCollisionStrategy)

        local instance, loadError = loadFn()
        if not instance then
                return {
                        action = sourceDetails.action,
                        success = false,
                        status = "error",
                        message = loadError,
                        details = sourceDetails,
                }
        end

        local name, collisionDetails = resolveNameCollision(parent, instance, operation.desiredName, collisionStrategy)
        if not name then
                instance:Destroy()
                local message = "Skipped insertion due to name collision"
                if collisionDetails and collisionDetails.conflictedName then
                        message = string.format("Skipped insertion because '%s' already exists", collisionDetails.conflictedName)
                end
                return {
                        action = sourceDetails.action,
                        success = false,
                        status = "skipped",
                        message = message,
                        details = collisionDetails,
                }
        end

        instance.Name = name
        instance.Parent = parent

        local placementOptions = operation.placement or defaults.defaultPlacement
        local placementDetails = applyPlacement(instance, placementOptions)

        local packageDetails: { [string]: any }? = nil
        if operation.saveAsPackage ~= nil then
                if type(operation.saveAsPackage) ~= "table" then
                        instance.Parent = nil
                        instance:Destroy()
                        return {
                                action = sourceDetails.action,
                                success = false,
                                status = "error",
                                message = "saveAsPackage must be an object when provided",
                                details = { asset = sourceDetails },
                        }
                end

                local packageSuccess, packageError, metadata = publishInstanceAsPackage(instance, operation.saveAsPackage)
                if not packageSuccess then
                        instance.Parent = nil
                        instance:Destroy()
                        return {
                                action = sourceDetails.action,
                                success = false,
                                status = "error",
                                message = packageError or "Failed to publish package",
                                details = {
                                        asset = sourceDetails,
                                        collision = collisionDetails,
                                },
                        }
                end
                packageDetails = metadata
        end

        local resultDetails: { [string]: any } = {
                asset = sourceDetails,
                parentPath = describeInstancePath(parent),
                instancePath = describeInstancePath(instance),
                collision = collisionDetails,
                placement = placementDetails,
                package = packageDetails,
                parentWarning = parentWarning,
        }

        if not parentWarning then
                resultDetails.parentWarning = nil
        end
        if not collisionDetails then
                resultDetails.collision = nil
        end
        if not placementDetails then
                resultDetails.placement = nil
        end
        if not packageDetails then
                resultDetails.package = nil
        end

        return {
                action = sourceDetails.action,
                success = true,
                status = "completed",
                message = string.format("Inserted '%s' into %s", instance.Name, parent:GetFullName()),
                details = resultDetails,
        }
end

local function processInsertAssetVersion(defaults: Types.AssetPipelineRequest, operation: Types.AssetPipelineInsertAssetVersion)
        local function loader()
                return loadAssetVersion(operation.assetVersionId)
        end

        local source = {
                action = "insert_asset_version",
                assetId = operation.assetId,
                assetVersionId = operation.assetVersionId,
        }

        return processInsertOrImport(defaults, operation, loader, source)
end

local function processImportRbxm(defaults: Types.AssetPipelineRequest, operation: Types.AssetPipelineImportRbxm)
        if type(operation.filePath) ~= "string" or operation.filePath == "" then
                return {
                        action = "import_rbxm",
                        success = false,
                        status = "error",
                        message = "import_rbxm requires a valid filePath",
                }
        end

        local function loader()
                return loadLocalAsset(operation.filePath)
        end

        local source = {
                action = "import_rbxm",
                filePath = operation.filePath,
        }

        return processInsertOrImport(defaults, operation, loader, source)
end

local function processPublishPackage(operation: Types.AssetPipelinePublishPackage)
        local instance, err = resolveInstance(operation.instancePath)
        if not instance then
                return {
                        action = "publish_package",
                        success = false,
                        status = "error",
                        message = err or "Unable to resolve instance for package publishing",
                        details = { instancePath = operation.instancePath },
                }
        end

        local success, publishError, metadata = publishInstanceAsPackage(instance, operation.publish)
        if not success then
                return {
                        action = "publish_package",
                        success = false,
                        status = "error",
                        message = publishError or "Failed to publish package",
                        details = { instancePath = describeInstancePath(instance) },
                }
        end

        return {
                action = "publish_package",
                success = true,
                status = "completed",
                message = string.format("Published package from %s", instance:GetFullName()),
                details = metadata,
        }
end

local function handleAssetPipeline(args: Types.ToolArgs): string?
        if args.tool ~= "AssetPipeline" then
                return nil
        end

        local params = args.params
        if type(params) ~= "table" then
                error("Missing params in AssetPipeline payload")
        end

        local operations = params.operations
        if type(operations) ~= "table" then
                error("AssetPipeline requires an operations array")
        end

        local defaults: Types.AssetPipelineRequest = params

        local results: { Types.AssetPipelineOperationResult } = {}
        local successCount = 0
        for _, operation in operations do
                local action = operation.action
                local result: Types.AssetPipelineOperationResult

                if action == "search_marketplace" then
                        result = processSearchMarketplace(operation)
                elseif action == "insert_asset_version" then
                        result = processInsertAssetVersion(defaults, operation)
                elseif action == "import_rbxm" then
                        result = processImportRbxm(defaults, operation)
                elseif action == "publish_package" then
                        result = processPublishPackage(operation)
                else
                        result = {
                                action = action or "unknown",
                                success = false,
                                status = "error",
                                message = string.format("Unsupported asset pipeline action '%s'", tostring(action)),
                        }
                end

                if result.success then
                        successCount += 1
                end

                table.insert(results, result)
        end

        local summary = if #results > 0
                then string.format("Completed %d of %d asset pipeline operations", successCount, #results)
                else "No asset pipeline operations were provided"

        return jsonEncode({ results = results, summary = summary })
end

return handleAssetPipeline :: Types.ToolFunction
