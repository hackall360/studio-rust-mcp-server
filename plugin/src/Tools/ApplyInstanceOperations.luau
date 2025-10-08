local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")

type ApplyInstanceOperation = Types.ApplyInstanceOperation
type ApplyInstanceOperationsArgs = Types.ApplyInstanceOperationsArgs
type ApplyInstanceOperationResult = Types.ApplyInstanceOperationResult
type ApplyInstanceOperationsResponse = Types.ApplyInstanceOperationsResponse

local CREATE_CLASS_ALLOWLIST = {
        Folder = true,
        Model = true,
        Part = true,
        MeshPart = true,
        WedgePart = true,
        CornerWedgePart = true,
        UnionOperation = true,
        PointLight = true,
        SpotLight = true,
        SurfaceLight = true,
        BillboardGui = true,
        ScreenGui = true,
        Attachment = true,
}

local ROOT_DELETE_ALLOWLIST = {
        Folder = true,
        Model = true,
}

local PROPERTY_ALLOWLIST: { [string]: { [string]: true } } = {
        Instance = {
                Name = true,
        },
        BasePart = {
                Anchored = true,
                CFrame = true,
                Color = true,
                Material = true,
                Orientation = true,
                Position = true,
                Reflectance = true,
                Size = true,
                Transparency = true,
        },
        Model = {
                PrimaryPart = true,
                WorldPivot = true,
        },
        Light = {
                Brightness = true,
                Color = true,
                Enabled = true,
                Range = true,
        },
        SurfaceGui = {
                Adornee = true,
                Enabled = true,
                LightInfluence = true,
        },
        BillboardGui = {
                Adornee = true,
                AlwaysOnTop = true,
                Enabled = true,
                LightInfluence = true,
                Size = true,
        },
        GuiObject = {
                Size = true,
                Position = true,
                AnchorPoint = true,
                BackgroundColor3 = true,
                BackgroundTransparency = true,
                BorderSizePixel = true,
                Visible = true,
        },
        Attachment = {
                CFrame = true,
                Position = true,
                Orientation = true,
        },
}

local function clonePath(path: Types.InstancePath): { string }
        local result = {}
        if type(path) ~= "table" then
                return result
        end

        local count = #path
        if count > 0 then
                result = table.create(count)
                for _, segment in path do
                        table.insert(result, segment)
                end
        end

        return result
end

local function normalisePath(path: Types.InstancePath): { string }
        local normalised = {}
        if type(path) ~= "table" then
                return normalised
        end
        for _, segment in path do
                if segment ~= "" and segment ~= "game" and segment ~= "DataModel" then
                        table.insert(normalised, segment)
                end
        end
        return normalised
end

local function resolveInstance(path: Types.InstancePath): (Instance?, string?)
        if type(path) ~= "table" then
                return nil, "Instance path must be an array of names"
        end
        local normalised = normalisePath(path)
        if #normalised == 0 then
                return game, nil
        end

        local current: Instance = game
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

local function isPropertyAllowed(instance: Instance, propertyName: string): boolean
        for className, allowed in PROPERTY_ALLOWLIST do
                if instance:IsA(className) and allowed[propertyName] then
                        return true
                end
        end
        return false
end

local function decodePropertyValue(value: any): any
        if type(value) ~= "table" then
                return value
        end

        local typeMarker = value.__type or value.type
        if typeMarker == "Vector3" then
                local x = value.x or value.X
                local y = value.y or value.Y
                local z = value.z or value.Z
                if type(x) == "number" and type(y) == "number" and type(z) == "number" then
                        return Vector3.new(x, y, z)
                end
        elseif typeMarker == "Color3" then
                local r = value.r or value.R
                local g = value.g or value.G
                local b = value.b or value.B
                if type(r) == "number" and type(g) == "number" and type(b) == "number" then
                        return Color3.new(r, g, b)
                end
        elseif typeMarker == "CFrame" then
                local components = value.components or value.value
                if type(components) == "table" and #components == 12 then
                        return CFrame.new(table.unpack(components))
                end
        elseif typeMarker == "UDim2" then
                local xScale = value.xScale or value.XScale or 0
                local xOffset = value.xOffset or value.XOffset or 0
                local yScale = value.yScale or value.YScale or 0
                local yOffset = value.yOffset or value.YOffset or 0
                if typeof(xScale) == "number" and typeof(xOffset) == "number" and typeof(yScale) == "number" and typeof(yOffset) == "number" then
                        return UDim2.new(xScale, xOffset, yScale, yOffset)
                end
        end

        return value
end

local function setProperty(instance: Instance, propertyName: string, value: any): (boolean, string?)
        if not isPropertyAllowed(instance, propertyName) then
                return false, string.format("Property '%s' cannot be edited on %s", propertyName, instance.ClassName)
        end

        local converted = decodePropertyValue(value)
        local ok, err = pcall(function()
                instance[propertyName] = converted
        end)

        if not ok then
                return false, string.format("Failed to set %s.%s: %s", instance:GetFullName(), propertyName, tostring(err))
        end

        return true, nil
end

local function applyCreate(operation: ApplyInstanceOperation): (boolean, string?)
        local className = operation.className
        if type(className) ~= "string" then
                return false, "Create operations require a className"
        end
        if not CREATE_CLASS_ALLOWLIST[className] then
                return false, string.format("Creation of '%s' instances is not permitted", className)
        end

        local path = operation.path
        if type(path) ~= "table" or #path == 0 then
                return false, "Create operations require a destination path"
        end

        local normalised = normalisePath(path)
        if #normalised == 0 then
                return false, "Create operations cannot target the DataModel root"
        end

        local parentPath = clonePath(normalised)
        local desiredName = operation.name or parentPath[#parentPath]
        table.remove(parentPath, #parentPath)

        if type(desiredName) ~= "string" or desiredName == "" then
                return false, "Create operations require a final path segment or explicit name"
        end

        local parent, parentError = resolveInstance(parentPath)
        if not parent then
                return false, parentError
        end

        if parent:FindFirstChild(desiredName) then
                return false, string.format("An instance named '%s' already exists under %s", desiredName, parent:GetFullName())
        end

        local instance = Instance.new(className)
        instance.Name = desiredName

        if type(operation.properties) == "table" then
                for propertyName, propertyValue in operation.properties do
                        if propertyName ~= "Parent" and propertyName ~= "Name" then
                                local success, message = setProperty(instance, propertyName, propertyValue)
                                if not success then
                                        instance:Destroy()
                                        return false, message
                                end
                        end
                end
        end

        local ok, message = pcall(function()
                instance.Parent = parent
        end)
        if not ok then
                instance:Destroy()
                return false, string.format("Failed to parent new %s '%s': %s", className, desiredName, tostring(message))
        end

        return true, string.format("Created %s '%s'", className, instance:GetFullName())
end

local function applyUpdate(operation: ApplyInstanceOperation): (boolean, string?)
        if type(operation.path) ~= "table" then
                return false, "Update operations require a valid instance path"
        end

        local target, errorMessage = resolveInstance(operation.path)
        if not target then
                return false, errorMessage
        end

        local properties = operation.properties
        if type(properties) ~= "table" then
                return false, "Update operations require a properties table"
        end

        local lastError: string? = nil
        local failedMessages = {}
        local applied = 0
        for propertyName, propertyValue in properties do
                if propertyName ~= "Parent" then
                        local success, message = setProperty(target, propertyName, propertyValue)
                        if success then
                                applied += 1
                        else
                                lastError = message
                                table.insert(failedMessages, message)
                        end
                end
        end

        if applied == 0 then
                return false, lastError or "No properties were updated"
        end

        local response = string.format(
                "Updated %d propert%s on %s",
                applied,
                applied == 1 and "y" or "ies",
                target:GetFullName()
        )
        if #failedMessages > 0 then
                response ..= " (" .. table.concat(failedMessages, "; ") .. ")"
        end

        return true, response
end

local function applyDelete(operation: ApplyInstanceOperation): (boolean, string?)
        if type(operation.path) ~= "table" then
                return false, "Delete operations require a valid instance path"
        end

        local target, errorMessage = resolveInstance(operation.path)
        if not target then
                return false, errorMessage
        end

        if target == game then
                return false, "Destroying the DataModel root is not permitted"
        end

        if target.Parent == game then
                local className = target.ClassName
                if className:sub(-7) == "Service" then
                        return false, string.format("Destroying %s services is not permitted", className)
                end
                if not ROOT_DELETE_ALLOWLIST[className] then
                        return false, string.format("Destroying top-level %s instances is not permitted", className)
                end
        end

        local ok, err = pcall(function()
                target:Destroy()
        end)

        if not ok then
                return false, string.format("Failed to destroy %s: %s", target:GetFullName(), tostring(err))
        end

        return true, string.format("Destroyed %s", target:GetFullName())
end

local ACTION_HANDLERS: { [Types.InstanceOperationAction]: (ApplyInstanceOperation) -> (boolean, string?) } = {
        create = applyCreate,
        update = applyUpdate,
        delete = applyDelete,
}

local function applyOperations(params: ApplyInstanceOperationsArgs): ApplyInstanceOperationsResponse
        local operations = params.operations
        if type(operations) ~= "table" or #operations == 0 then
                error("apply_instance_operations requires at least one operation")
        end

        local recording = ChangeHistoryService:TryBeginRecording("ApplyInstanceOperations")
        if recording then
                ChangeHistoryService:SetWaypoint("Before ApplyInstanceOperations")
        end

        local results: { ApplyInstanceOperationResult } = table.create(#operations)
        local successes = 0

        for index, operation in operations do
                local handler = ACTION_HANDLERS[operation.action]
                if not handler then
                        results[index] = {
                                index = index,
                                action = operation.action,
                                path = clonePath(operation.path),
                                success = false,
                                message = string.format("Unsupported action '%s'", tostring(operation.action)),
                        }
                else
                        local success, message = handler(operation)
                        if success then
                                successes += 1
                        end
                        results[index] = {
                                index = index,
                                action = operation.action,
                                path = clonePath(operation.path),
                                success = success,
                                message = message,
                        }
                end
        end

        if recording then
                        if successes > 0 then
                                ChangeHistoryService:SetWaypoint("After ApplyInstanceOperations")
                                ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
                        else
                                ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
                        end
        end

        local total = #operations
        local failures = total - successes
        local summary = string.format("Applied %d of %d operations", successes, total)
        if failures > 0 then
                summary ..= string.format(" (%d failed)", failures)
        end

        return {
                results = results,
                summary = summary,
                writeOccurred = successes > 0,
        }
end

local function handleApplyInstanceOperations(args: Types.ToolArgs): string?
        if args.tool ~= "ApplyInstanceOperations" then
                return nil
        end

        local params = args.params
        if type(params) ~= "table" then
                error("Missing params in ApplyInstanceOperations payload")
        end

        local encoded = HttpService:JSONEncode(applyOperations(params))
        return encoded
end

return handleApplyInstanceOperations :: Types.ToolFunction
