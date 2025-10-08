local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterGui = game:GetService("StarterGui")
local StarterPack = game:GetService("StarterPack")
local StarterPlayer = game:GetService("StarterPlayer")

type ApplyInstanceOperation = Types.ApplyInstanceOperation
type ApplyInstanceOperationsArgs = Types.ApplyInstanceOperationsArgs
type ApplyInstanceOperationResult = Types.ApplyInstanceOperationResult
type ApplyInstanceOperationsResponse = Types.ApplyInstanceOperationsResponse
type InstancePath = Types.InstancePath
type PropertyMap = Types.PropertyMap
type AttributeMap = Types.AttributeMap

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
        Sound = true,
        ParticleEmitter = true,
        Trail = true,
        Decal = true,
        Texture = true,
        Humanoid = true,
        UIGradient = true,
}

local MAX_CLONE_COUNT = 25

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
        Sound = {
                SoundId = true,
                Volume = true,
                PlaybackSpeed = true,
                Looped = true,
                Playing = true,
                TimePosition = true,
                RollOffMaxDistance = true,
                RollOffMinDistance = true,
        },
        ParticleEmitter = {
                Color = true,
                Texture = true,
                Transparency = true,
                Size = true,
                Lifetime = true,
                Speed = true,
                EmissionRate = true,
                Rate = true,
                Enabled = true,
                LightInfluence = true,
                LightEmission = true,
        },
        Trail = {
                Color = true,
                Transparency = true,
                Lifetime = true,
                MinLength = true,
                MaxLength = true,
                Enabled = true,
                WidthScale = true,
                Attachment0 = true,
                Attachment1 = true,
        },
        Decal = {
                Texture = true,
                Color3 = true,
                Transparency = true,
                Face = true,
        },
        Texture = {
                Texture = true,
                Color3 = true,
                Transparency = true,
                StudsPerTileU = true,
                StudsPerTileV = true,
                Face = true,
        },
        Humanoid = {
                WalkSpeed = true,
                JumpPower = true,
                AutoRotate = true,
                HipHeight = true,
                Health = true,
                MaxHealth = true,
        },
        UIGradient = {
                Color = true,
                Transparency = true,
                Rotation = true,
                Enabled = true,
        },
        TextLabel = {
                Text = true,
                TextColor3 = true,
                TextSize = true,
                Font = true,
                RichText = true,
                TextTransparency = true,
        },
        TextButton = {
                Text = true,
                TextColor3 = true,
                TextSize = true,
                Font = true,
                RichText = true,
                TextTransparency = true,
        },
}

local function clonePath(path: InstancePath?): { string }
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

local function normalisePath(path: InstancePath): { string }
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

local function getInstancePathSegments(instance: Instance): { string }
        local segments = {}
        local current: Instance? = instance
        while current and current ~= game do
                table.insert(segments, 1, current.Name)
                current = current.Parent
        end
        return segments
end

local function clonePaths(paths: { InstancePath }?): { { string } }
        local results: { { string } } = {}
        if type(paths) ~= "table" then
                return results
        end

        for _, path in paths do
                table.insert(results, clonePath(path))
        end

        return results
end

local function isDescendantOf(instance: Instance?, ancestor: Instance?): boolean
        if not instance or not ancestor then
                return false
        end

        if instance == ancestor then
                return true
        end

        local ok, result = pcall(function()
                return instance:IsDescendantOf(ancestor)
        end)

        if not ok then
                return false
        end

        return result
end

local function validateScriptPlacement(instance: Instance, parent: Instance): (boolean, string?)
        if instance:IsA("LocalScript") then
                if isDescendantOf(parent, ServerScriptService) then
                        return false, "LocalScripts cannot run under ServerScriptService"
                end
                if isDescendantOf(parent, ServerStorage) then
                        return false, "LocalScripts cannot run under ServerStorage"
                end
        elseif instance:IsA("Script") then
                if isDescendantOf(parent, StarterGui) then
                        return false, "Server Scripts cannot run inside StarterGui"
                end
                if isDescendantOf(parent, StarterPack) then
                        return false, "Server Scripts cannot run inside StarterPack"
                end
                if isDescendantOf(parent, StarterPlayer) then
                        return false, "Server Scripts cannot run inside StarterPlayer containers"
                end
        end

        return true, nil
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

local function applyProperties(instance: Instance, properties: PropertyMap?, options: { skipName: boolean }?): (number, { string })
        if type(properties) ~= "table" then
                return 0, {}
        end

        local applied = 0
        local errors = {}
        local skipName = options ~= nil and options.skipName == true

        for propertyName, propertyValue in properties do
                if typeof(propertyName) == "string" then
                        if propertyName ~= "Parent" and (not skipName or propertyName ~= "Name") then
                                local success, message = setProperty(instance, propertyName, propertyValue)
                                if success then
                                        applied += 1
                                elseif message then
                                        table.insert(errors, message)
                                end
                        end
                end
        end

        return applied, errors
end

local function applyAttributes(instance: Instance, attributes: AttributeMap?): (number, { string })
        if type(attributes) ~= "table" then
                return 0, {}
        end

        local applied = 0
        local errors = {}

        for attributeName, attributeValue in attributes do
                if typeof(attributeName) == "string" and attributeName ~= "" then
                        local ok, err = pcall(function()
                                instance:SetAttribute(attributeName, attributeValue)
                        end)

                        if ok then
                                applied += 1
                        else
                                table.insert(
                                        errors,
                                        string.format(
                                                "Failed to set attribute '%s' on %s: %s",
                                                attributeName,
                                                instance:GetFullName(),
                                                tostring(err)
                                        )
                                )
                        end
                else
                        table.insert(errors, "Attribute names must be non-empty strings")
                end
        end

        return applied, errors
end

local function reserveUniqueName(parent: Instance, desiredName: string, reserved: { [string]: boolean }): string
        local baseName = desiredName
        if typeof(baseName) ~= "string" or baseName == "" then
                baseName = "Clone"
        end

        local uniqueName = baseName
        local suffix = 1

        while parent:FindFirstChild(uniqueName) or reserved[uniqueName] do
                uniqueName = string.format("%s (%d)", baseName, suffix)
                suffix += 1
                if suffix > 100 then
                        uniqueName = baseName .. " " .. HttpService:GenerateGUID(false)
                        break
                end
        end

        reserved[uniqueName] = true
        return uniqueName
end

local function getPrimaryPath(operation: ApplyInstanceOperation): InstancePath
        if type(operation.path) == "table" then
                return operation.path
        end

        local targetPaths = (operation :: any).targetPaths
        if type(targetPaths) == "table" and #targetPaths > 0 then
                return targetPaths[1]
        end

        return {}
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

        local propertyCount, propertyErrors = applyProperties(instance, operation.properties, { skipName = true })
        if #propertyErrors > 0 then
                instance:Destroy()
                return false, table.concat(propertyErrors, "; ")
        end

        local okPlacement, placementError = validateScriptPlacement(instance, parent)
        if not okPlacement then
                instance:Destroy()
                return false, placementError
        end

        local ok, message = pcall(function()
                instance.Parent = parent
        end)
        if not ok then
                instance:Destroy()
                return false, string.format("Failed to parent new %s '%s': %s", className, desiredName, tostring(message))
        end

        local attributeCount, attributeErrors = applyAttributes(instance, operation.attributes)
        if #attributeErrors > 0 then
                local summary = table.concat(attributeErrors, "; ")
                instance:Destroy()
                return false, summary
        end

        local response = string.format("Created %s '%s'", className, instance:GetFullName())
        local details = {}
        if propertyCount > 0 then
                table.insert(details, string.format("applied %d propert%s", propertyCount, propertyCount == 1 and "y" or "ies"))
        end
        if attributeCount > 0 then
                table.insert(details, string.format("synced %d attribute%s", attributeCount, attributeCount == 1 and "" or "s"))
        end
        if #details > 0 then
                response ..= " (" .. table.concat(details, ", ") .. ")"
        end

        return true, response
end

local function applyUpdate(operation: ApplyInstanceOperation): (boolean, string?)
        if type(operation.path) ~= "table" then
                return false, "Update operations require a valid instance path"
        end

        local target, errorMessage = resolveInstance(operation.path)
        if not target then
                return false, errorMessage
        end

        local properties = if type(operation.properties) == "table" then operation.properties else nil
        local attributes = if type(operation.attributes) == "table" then operation.attributes else nil

        if (properties == nil or next(properties) == nil) and (attributes == nil or next(attributes) == nil) then
                return false, "Update operations require properties or attributes to apply"
        end

        local propertyCount, propertyErrors = applyProperties(target, properties, nil)
        local attributeCount, attributeErrors = applyAttributes(target, attributes)

        local totalApplied = propertyCount + attributeCount
        if totalApplied == 0 then
                local lastError = propertyErrors[1] or attributeErrors[1]
                return false, lastError or "No updates were applied"
        end

        local responseDetails = {}
        if propertyCount > 0 then
                table.insert(responseDetails, string.format("updated %d propert%s", propertyCount, propertyCount == 1 and "y" or "ies"))
        end
        if attributeCount > 0 then
                table.insert(responseDetails, string.format("synced %d attribute%s", attributeCount, attributeCount == 1 and "" or "s"))
        end

        local response = table.concat(responseDetails, " and ") .. " on " .. target:GetFullName()

        local allErrors = {}
        for _, message in propertyErrors do
                table.insert(allErrors, message)
        end
        for _, message in attributeErrors do
                table.insert(allErrors, message)
        end
        if #allErrors > 0 then
                response ..= " (" .. table.concat(allErrors, "; ") .. ")"
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

local function applyReparent(operation: ApplyInstanceOperation): (boolean, string?, { { string } }?)
        if type(operation.path) ~= "table" then
                return false, "Reparent operations require a valid instance path"
        end

        local target, targetError = resolveInstance(operation.path)
        if not target then
                return false, targetError
        end

        if target == game then
                return false, "Reparenting the DataModel root is not permitted"
        end

        local newParentPath = (operation :: any).newParentPath
        if type(newParentPath) ~= "table" or #newParentPath == 0 then
                return false, "Reparent operations require newParentPath"
        end

        local newParent, parentError = resolveInstance(newParentPath)
        if not newParent then
                return false, parentError
        end

        if newParent == target then
                return false, "An instance cannot be parented to itself"
        end

        if isDescendantOf(newParent, target) then
                return false, "Cannot reparent an instance into one of its descendants"
        end

        local desiredName = (operation :: any).name
        if type(desiredName) ~= "string" or desiredName == "" then
                desiredName = target.Name
        end

        local existing = newParent:FindFirstChild(desiredName)
        if existing and existing ~= target then
                return false, string.format("An instance named '%s' already exists under %s", desiredName, newParent:GetFullName())
        end

        local okPlacement, placementError = validateScriptPlacement(target, newParent)
        if not okPlacement then
                return false, placementError
        end

        local ok, parentErr = pcall(function()
                target.Parent = newParent
        end)
        if not ok then
                return false, string.format("Failed to reparent %s: %s", target:GetFullName(), tostring(parentErr))
        end

        if desiredName ~= target.Name then
                target.Name = desiredName
        end

        local propertyCount, propertyErrors = applyProperties(target, (operation :: any).properties, { skipName = true })
        local attributeCount, attributeErrors = applyAttributes(target, (operation :: any).attributes)

        local notes = {}
        if propertyCount > 0 then
                table.insert(notes, string.format("applied %d propert%s", propertyCount, propertyCount == 1 and "y" or "ies"))
        end
        if attributeCount > 0 then
                table.insert(notes, string.format("synced %d attribute%s", attributeCount, attributeCount == 1 and "" or "s"))
        end

        local warnings = {}
        for _, message in propertyErrors do
                table.insert(warnings, message)
        end
        for _, message in attributeErrors do
                table.insert(warnings, message)
        end
        if #warnings > 0 then
                table.insert(notes, "warnings: " .. table.concat(warnings, "; "))
        end

        local response = string.format("Reparented %s to %s", target:GetFullName(), newParent:GetFullName())
        if #notes > 0 then
                response ..= " (" .. table.concat(notes, "; ") .. ")"
        end

        local affectedPaths = {
                clonePath(operation.path),
                getInstancePathSegments(target),
        }

        return true, response, affectedPaths
end

local function applyClone(operation: ApplyInstanceOperation): (boolean, string?, { { string } }?)
        if type(operation.path) ~= "table" then
                return false, "Clone operations require a valid instance path"
        end

        local target, errorMessage = resolveInstance(operation.path)
        if not target then
                return false, errorMessage
        end

        if target == game then
                return false, "Cloning the DataModel root is not permitted"
        end

        local cloneCountValue = (operation :: any).cloneCount
        local cloneCount = if typeof(cloneCountValue) == "number" then math.floor(cloneCountValue) else 1
        if cloneCount < 1 then
                return false, "cloneCount must be at least 1"
        end
        if cloneCount > MAX_CLONE_COUNT then
                return false, string.format("cloneCount exceeds maximum of %d", MAX_CLONE_COUNT)
        end

        local parent: Instance? = nil
        local newParentPath = (operation :: any).newParentPath
        if type(newParentPath) == "table" and #newParentPath > 0 then
                local resolvedParent, parentError = resolveInstance(newParentPath)
                if not resolvedParent then
                        return false, parentError
                end
                parent = resolvedParent
        else
                parent = target.Parent
        end

        if not parent then
                return false, "Clone operations require a destination parent"
        end

        local okPlacement, placementError = validateScriptPlacement(target, parent)
        if not okPlacement then
                return false, placementError
        end

        local baseNameValue = (operation :: any).name
        local baseName = if typeof(baseNameValue) == "string" and baseNameValue ~= "" then baseNameValue else target.Name

        local reservedNames: { [string]: boolean } = {}
        local clones: { Instance } = {}
        local clonePathSegments: { { string } } = {}
        local totalPropertyCount = 0
        local totalAttributeCount = 0
        local warnings = {}

        for index = 1, cloneCount do
                local clone = target:Clone()

                local desiredName = baseName
                if cloneCount > 1 then
                        desiredName = string.format("%s (%d)", baseName, index)
                end
                local uniqueName = reserveUniqueName(parent, desiredName, reservedNames)
                clone.Name = uniqueName

                local okParent, parentError = pcall(function()
                        clone.Parent = parent
                end)
                if not okParent then
                        clone:Destroy()
                        for _, created in clones do
                                created:Destroy()
                        end
                        return false, string.format("Failed to parent clone '%s': %s", uniqueName, tostring(parentError))
                end

                local propertyCount, propertyErrors = applyProperties(clone, (operation :: any).properties, { skipName = true })
                local attributeCount, attributeErrors = applyAttributes(clone, (operation :: any).attributes)

                totalPropertyCount += propertyCount
                totalAttributeCount += attributeCount

                for _, message in propertyErrors do
                        table.insert(warnings, message)
                end
                for _, message in attributeErrors do
                        table.insert(warnings, message)
                end

                table.insert(clones, clone)
                table.insert(clonePathSegments, getInstancePathSegments(clone))
        end

        local response = string.format(
                "Cloned %s into %s (%d clone%s)",
                target:GetFullName(),
                parent:GetFullName(),
                cloneCount,
                cloneCount == 1 and "" or "s"
        )

        local notes = {}
        if totalPropertyCount > 0 then
                table.insert(notes, string.format("applied %d propert%s", totalPropertyCount, totalPropertyCount == 1 and "y" or "ies"))
        end
        if totalAttributeCount > 0 then
                table.insert(notes, string.format("synced %d attribute%s", totalAttributeCount, totalAttributeCount == 1 and "" or "s"))
        end
        if #warnings > 0 then
                table.insert(notes, "warnings: " .. table.concat(warnings, "; "))
        end
        if #notes > 0 then
                response ..= " (" .. table.concat(notes, "; ") .. ")"
        end

        return true, response, clonePathSegments
end

local function applyBulkSetProperties(operation: ApplyInstanceOperation): (boolean, string?, { { string } }?)
        local targetPaths = (operation :: any).targetPaths
        if type(targetPaths) ~= "table" or #targetPaths == 0 then
                return false, "bulk_set_properties operations require targetPaths"
        end

        local properties = if type((operation :: any).properties) == "table" then (operation :: any).properties else nil
        local attributes = if type((operation :: any).attributes) == "table" then (operation :: any).attributes else nil

        if (properties == nil or next(properties) == nil) and (attributes == nil or next(attributes) == nil) then
                return false, "bulk_set_properties requires properties or attributes to apply"
        end

        local successes = 0
        local totalPropertyCount = 0
        local totalAttributeCount = 0
        local warnings = {}
        local affectedPaths: { { string } } = {}

        for _, path in targetPaths do
                table.insert(affectedPaths, clonePath(path))
                local target, resolveError = resolveInstance(path)
                if not target or target == game then
                        table.insert(warnings, resolveError or "Unable to resolve target path")
                else
                        local propertyCount, propertyErrors = applyProperties(target, properties, nil)
                        local attributeCount, attributeErrors = applyAttributes(target, attributes)

                        if propertyCount + attributeCount > 0 then
                                successes += 1
                        end

                        totalPropertyCount += propertyCount
                        totalAttributeCount += attributeCount

                        for _, message in propertyErrors do
                                table.insert(warnings, message)
                        end
                        for _, message in attributeErrors do
                                table.insert(warnings, message)
                        end
                end
        end

        if successes == 0 then
                return false, warnings[1] or "No targets were updated", affectedPaths
        end

        local response = string.format("Updated %d of %d instances", successes, #targetPaths)
        local notes = {}
        if totalPropertyCount > 0 then
                table.insert(notes, string.format("applied %d propert%s", totalPropertyCount, totalPropertyCount == 1 and "y" or "ies"))
        end
        if totalAttributeCount > 0 then
                table.insert(notes, string.format("synced %d attribute%s", totalAttributeCount, totalAttributeCount == 1 and "" or "s"))
        end
        if #warnings > 0 then
                table.insert(notes, "warnings: " .. table.concat(warnings, "; "))
        end
        if #notes > 0 then
                response ..= " (" .. table.concat(notes, "; ") .. ")"
        end

        return true, response, affectedPaths
end

local ACTION_HANDLERS: { [Types.InstanceOperationAction]: (ApplyInstanceOperation) -> (boolean, string?, { { string } }?) } = {
        create = function(operation)
                local success, message = applyCreate(operation)
                return success, message, nil
        end,
        update = function(operation)
                local success, message = applyUpdate(operation)
                return success, message, nil
        end,
        delete = function(operation)
                local success, message = applyDelete(operation)
                return success, message, nil
        end,
        reparent = applyReparent,
        clone = applyClone,
        bulk_set_properties = applyBulkSetProperties,
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
                        local primaryPath = getPrimaryPath(operation)
                        results[index] = {
                                index = index,
                                action = operation.action,
                                path = clonePath(primaryPath),
                                paths = {},
                                success = false,
                                message = string.format("Unsupported action '%s'", tostring(operation.action)),
                        }
                else
                        local success, message, affectedPaths = handler(operation)
                        if success then
                                successes += 1
                        end
                        local primaryPath = getPrimaryPath(operation)
                        local paths = affectedPaths
                        if paths == nil then
                                local targetPaths = (operation :: any).targetPaths
                                if type(targetPaths) == "table" and #targetPaths > 0 then
                                        paths = clonePaths(targetPaths)
                                elseif type(primaryPath) == "table" and #primaryPath > 0 then
                                        paths = { clonePath(primaryPath) }
                                else
                                        paths = {}
                                end
                        end
                        results[index] = {
                                index = index,
                                action = operation.action,
                                path = clonePath(primaryPath),
                                paths = paths,
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
