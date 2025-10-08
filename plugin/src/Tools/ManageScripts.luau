local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local StarterGui = game:GetService("StarterGui")
local StarterPack = game:GetService("StarterPack")

export type ScriptMetadataRequest = Types.ScriptMetadataRequest
export type ScriptMetadata = Types.ScriptMetadata
export type ScriptDiagnostic = Types.ScriptDiagnostic
export type ManageScriptOperation = Types.ManageScriptOperation
export type ManageScriptOperationResult = Types.ManageScriptOperationResult
export type ManageScriptsArgs = Types.ManageScriptsArgs
export type ManageScriptsResponse = Types.ManageScriptsResponse

local ALLOWED_SCRIPT_TYPES = {
        Script = true,
        LocalScript = true,
        ModuleScript = true,
}

local function normalisePath(path: Types.ScriptPath): { string }
        local normalised = {}
        if type(path) ~= "table" then
                return normalised
        end

        for _, segment in path do
                if typeof(segment) == "string" and segment ~= "" and segment ~= "game" and segment ~= "DataModel" then
                        table.insert(normalised, segment)
                end
        end

        return normalised
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

local function resolveInstance(path: Types.ScriptPath): (Instance?, string?)
        local normalised = normalisePath(path)
        if #normalised == 0 then
                return game, nil
        end

        local current: Instance = game
        for index, segment in normalised do
                local child = current:FindFirstChild(segment)
                if not child then
                        local parentName = if index == 1 then "game" else current:GetFullName()
                        return nil, string.format("Unable to find '%s' under %s", segment, parentName)
                end
                current = child
        end

        return current, nil
end

local function resolveScript(path: Types.ScriptPath): (LuaSourceContainer?, string?, { string }?)
        local instance, err = resolveInstance(path)
        if not instance then
                return nil, err, normalisePath(path)
        end

        if not instance:IsA("LuaSourceContainer") then
                return nil, string.format("%s is a %s, expected a script", instance:GetFullName(), instance.ClassName), normalisePath(path)
        end

        return instance :: LuaSourceContainer, nil, getInstancePathSegments(instance)
end

local function resolveCreateDestination(path: Types.ScriptPath): (Instance?, { string }?, string?, string?)
        local normalised = normalisePath(path)
        if #normalised == 0 then
                return nil, normalised, nil, "Create operations require a destination path"
        end

        local desiredName = normalised[#normalised]
        if type(desiredName) ~= "string" or desiredName == "" then
                return nil, normalised, nil, "The final path segment must be the new script name"
        end

        local parentPath = table.create(#normalised - 1)
        for index = 1, #normalised - 1 do
                table.insert(parentPath, normalised[index])
        end

        local parent, err = resolveInstance(parentPath)
        if not parent then
                return nil, normalised, nil, err
        end

        return parent, normalised, desiredName, nil
end

local function isDescendantOf(instance: Instance, ancestor: Instance): boolean
        if not ancestor then
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

local function validateScriptPlacement(scriptType: string, parent: Instance): (boolean, string?)
        if scriptType == "LocalScript" then
                if isDescendantOf(parent, ServerScriptService) then
                        return false, "LocalScripts cannot run under ServerScriptService"
                end
                if isDescendantOf(parent, ServerStorage) then
                        return false, "LocalScripts cannot run under ServerStorage"
                end
        elseif scriptType == "Script" then
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

local function cloneMetadataSelection(selection: ScriptMetadataRequest): ScriptMetadataRequest
        local clone: ScriptMetadataRequest = {}
        for key, value in selection do
                clone[key] = value
        end
        return clone
end

local function mergeMetadataSelection(defaultSelection: ScriptMetadataRequest?, overrideSelection: ScriptMetadataRequest?): ScriptMetadataRequest?
        if defaultSelection == nil then
                return overrideSelection
        end
        if overrideSelection == nil then
                return defaultSelection
        end

        local merged = cloneMetadataSelection(defaultSelection)
        for key, value in overrideSelection do
                merged[key] = value
        end
        return merged
end

local function gatherMetadata(scriptInstance: LuaSourceContainer, metadataRequest: ScriptMetadataRequest?): ScriptMetadata?
        if metadataRequest == nil then
                        return nil
        end

        local metadata: ScriptMetadata = {}
        if metadataRequest.includeClassName then
                metadata.className = scriptInstance.ClassName
        end
        if metadataRequest.includeFullName then
                metadata.fullName = scriptInstance:GetFullName()
        end
        if metadataRequest.includeParentPath then
                local parent = scriptInstance.Parent
                if parent then
                        metadata.parentPath = getInstancePathSegments(parent)
                else
                        metadata.parentPath = {}
                end
        end
        if metadataRequest.includeRunContext then
                local ok, runContext = pcall(function()
                        return (scriptInstance :: any).RunContext
                end)
                if ok and typeof(runContext) == "string" then
                        metadata.runContext = runContext
                end
        end
        if metadataRequest.includeAttributes then
                local ok, attributes = pcall(function()
                        return scriptInstance:GetAttributes()
                end)
                if ok then
                        metadata.attributes = attributes :: { [string]: any }
                end
        end

        if next(metadata) == nil then
                return nil
        end

        return metadata
end

local function validateSource(source: string): (boolean, { ScriptDiagnostic }?)
        local chunk, errorMessage = loadstring(source, "MCPManageScripts")
        if chunk then
                return true, nil
        end

        local diagnostics: { ScriptDiagnostic } = {}
        if type(errorMessage) == "string" then
                local lineWithColumn, column, message = string.match(errorMessage, ":(%d+):(%d+):%s*(.+)")
                if lineWithColumn and message then
                        table.insert(diagnostics, {
                                kind = "syntax",
                                message = message,
                                line = tonumber(lineWithColumn),
                                column = tonumber(column),
                        })
                else
                        local line, msg = string.match(errorMessage, ":(%d+):%s*(.+)")
                        table.insert(diagnostics, {
                                kind = "syntax",
                                message = msg or errorMessage,
                                line = line and tonumber(line) or nil,
                                column = nil,
                        })
                end
        end

        if #diagnostics == 0 then
                table.insert(diagnostics, {
                        kind = "syntax",
                        message = tostring(errorMessage),
                })
        end

        return false, diagnostics
end

local function applyAttributes(instance: Instance, attributes: { [string]: any }?): (boolean, string?)
        if type(attributes) ~= "table" then
                return true, nil
        end

        for key, value in attributes do
                if typeof(key) ~= "string" or key == "" then
                        return false, "Attribute keys must be non-empty strings"
                end

                local ok, err = pcall(function()
                        instance:SetAttribute(key, value)
                end)
                if not ok then
                        return false, string.format("Failed to set attribute '%s': %s", key, tostring(err))
                end
        end

        return true, nil
end

local function makeResult(
        action: string,
        path: { string },
        success: boolean,
        message: string?,
        metadata: ScriptMetadata?,
        diagnostics: { ScriptDiagnostic }?,
        details: { [string]: any }?,
        source: string?
): ManageScriptOperationResult
        local result: ManageScriptOperationResult = {
                action = action,
                path = path,
                success = success,
        }
        if message then
                result.message = message
        end
        if metadata and next(metadata) ~= nil then
                result.metadata = metadata
        end
        if diagnostics and #diagnostics > 0 then
                result.diagnostics = diagnostics
        end
        if details and next(details) ~= nil then
                result.details = details
        end
        if source then
                result.source = source
        end
        return result
end

local function processCreate(operation: Types.ManageScriptOperationCreate, metadataRequest: ScriptMetadataRequest?): ManageScriptOperationResult
        local scriptType = operation.scriptType
        if type(scriptType) ~= "string" or not ALLOWED_SCRIPT_TYPES[scriptType] then
                return makeResult(operation.action, normalisePath(operation.path), false, string.format("Unsupported script type '%s'", tostring(scriptType)), nil, nil, nil, nil)
        end

        local parent, normalised, desiredName, destinationError = resolveCreateDestination(operation.path)
        if not parent then
                return makeResult(operation.action, normalised, false, destinationError, nil, nil, nil, nil)
        end

        local okPlacement, placementError = validateScriptPlacement(scriptType, parent)
        if not okPlacement then
                return makeResult(operation.action, normalised, false, placementError, nil, nil, nil, nil)
        end

        if parent:FindFirstChild(desiredName) then
                return makeResult(operation.action, normalised, false, string.format("An instance named '%s' already exists under %s", desiredName, parent:GetFullName()), nil, nil, nil, nil)
        end

        local source = operation.source
        if source ~= nil then
                if type(source) ~= "string" then
                        return makeResult(operation.action, normalised, false, "Script source must be a string", nil, nil, nil, nil)
                end
                local valid, diagnostics = validateSource(source)
                if not valid then
                        return makeResult(operation.action, normalised, false, "Source failed syntax validation", nil, diagnostics, nil, nil)
                end
        end

        local newScript = Instance.new(scriptType)
        newScript.Name = desiredName

        if source then
                newScript.Source = source
        end

        if operation.runContext ~= nil then
                if typeof(operation.runContext) ~= "string" then
                        newScript:Destroy()
                        return makeResult(operation.action, normalised, false, "RunContext must be a string", nil, nil, nil, nil)
                end
                local ok, err = pcall(function()
                        (newScript :: any).RunContext = operation.runContext
                end)
                if not ok then
                        newScript:Destroy()
                        return makeResult(operation.action, normalised, false, string.format("Failed to set RunContext: %s", tostring(err)), nil, nil, nil, nil)
                end
        end

        local okAttributes, attributeError = applyAttributes(newScript, operation.attributes)
        if not okAttributes then
                        newScript:Destroy()
                        return makeResult(operation.action, normalised, false, attributeError, nil, nil, nil, nil)
        end

        local okParent, parentError = pcall(function()
                newScript.Parent = parent
        end)
        if not okParent then
                newScript:Destroy()
                return makeResult(operation.action, normalised, false, string.format("Failed to parent script: %s", tostring(parentError)), nil, nil, nil, nil)
        end

        local metadata = gatherMetadata(newScript, metadataRequest)
        local details = {
                created = true,
                className = newScript.ClassName,
                parentFullName = parent:GetFullName(),
        }
        local pathResult = getInstancePathSegments(newScript)
        return makeResult(operation.action, pathResult, true, string.format("Created %s", newScript:GetFullName()), metadata, nil, details, nil)
end

local function processGetSource(operation: Types.ManageScriptOperationGetSource, metadataRequest: ScriptMetadataRequest?): ManageScriptOperationResult
        local scriptInstance, err, resolvedPath = resolveScript(operation.path)
        if not scriptInstance then
                return makeResult(operation.action, resolvedPath, false, err, nil, nil, nil, nil)
        end

        local metadata = gatherMetadata(scriptInstance, metadataRequest)
        local details = {
                characters = #scriptInstance.Source,
        }
        return makeResult(operation.action, resolvedPath or getInstancePathSegments(scriptInstance), true, nil, metadata, nil, details, scriptInstance.Source)
end

local function processSetSource(operation: Types.ManageScriptOperationSetSource, metadataRequest: ScriptMetadataRequest?): ManageScriptOperationResult
        local scriptInstance, err, resolvedPath = resolveScript(operation.path)
        if not scriptInstance then
                return makeResult(operation.action, resolvedPath, false, err, nil, nil, nil, nil)
        end

        if type(operation.source) ~= "string" then
                return makeResult(operation.action, resolvedPath or getInstancePathSegments(scriptInstance), false, "New script source must be a string", nil, nil, nil, nil)
        end

        local previousSource = scriptInstance.Source
        local valid, diagnostics = validateSource(operation.source)
        if not valid then
                return makeResult(operation.action, resolvedPath or getInstancePathSegments(scriptInstance), false, "Source failed syntax validation", nil, diagnostics, nil, nil)
        end

        local ok, setError = pcall(function()
                scriptInstance.Source = operation.source
        end)
        if not ok then
                return makeResult(operation.action, resolvedPath or getInstancePathSegments(scriptInstance), false, string.format("Failed to update source: %s", tostring(setError)), nil, nil, nil, nil)
        end

        local metadata = gatherMetadata(scriptInstance, metadataRequest)
        local details = {
                characters = #operation.source,
                previousCharacters = #previousSource,
                changed = previousSource ~= operation.source,
        }
        return makeResult(operation.action, resolvedPath or getInstancePathSegments(scriptInstance), true, string.format("Updated %s", scriptInstance:GetFullName()), metadata, nil, details, scriptInstance.Source)
end

local function processRename(operation: Types.ManageScriptOperationRename, metadataRequest: ScriptMetadataRequest?): ManageScriptOperationResult
        local scriptInstance, err, resolvedPath = resolveScript(operation.path)
        if not scriptInstance then
                return makeResult(operation.action, resolvedPath, false, err, nil, nil, nil, nil)
        end

        if type(operation.newName) ~= "string" or operation.newName == "" then
                return makeResult(operation.action, resolvedPath or getInstancePathSegments(scriptInstance), false, "New name must be a non-empty string", nil, nil, nil, nil)
        end

        if scriptInstance.Name ~= operation.newName and scriptInstance.Parent then
                local sibling = scriptInstance.Parent:FindFirstChild(operation.newName)
                if sibling and sibling ~= scriptInstance then
                        return makeResult(operation.action, resolvedPath or getInstancePathSegments(scriptInstance), false, string.format("An instance named '%s' already exists under %s", operation.newName, scriptInstance.Parent:GetFullName()), nil, nil, nil, nil)
                end
        end

        local previousName = scriptInstance.Name
        local previousPathSegments = resolvedPath or getInstancePathSegments(scriptInstance)

        local successRename, renameError = pcall(function()
                scriptInstance.Name = operation.newName
        end)
        if not successRename then
                return makeResult(operation.action, resolvedPath or getInstancePathSegments(scriptInstance), false, string.format("Failed to rename script: %s", tostring(renameError)), nil, nil, nil, nil)
        end

        local metadata = gatherMetadata(scriptInstance, metadataRequest)
        local details = {
                previousName = previousName,
                currentName = scriptInstance.Name,
                previousPath = previousPathSegments,
        }

        local newPath = getInstancePathSegments(scriptInstance)
        return makeResult(operation.action, newPath, true, string.format("Renamed script to '%s'", scriptInstance.Name), metadata, nil, details, nil)
end

local PROCESSORS = {
        create = processCreate,
        get_source = processGetSource,
        set_source = processSetSource,
        rename = processRename,
}

local function handleManageScripts(args: Types.ToolArgs): string?
        if args.tool ~= "ManageScripts" then
                return nil
        end

        local params = args.params
        if type(params) ~= "table" then
                error("Missing params in ManageScripts payload")
        end

        local operations = params.operations
        if type(operations) ~= "table" then
                error("ManageScripts payload requires an operations array")
        end

        local defaultMetadata: ScriptMetadataRequest? = params.defaultMetadata

        local results: { ManageScriptOperationResult } = {}
        local successCount = 0
        local failureCount = 0

        for _, operation in operations do
                if type(operation) ~= "table" then
                        table.insert(results, makeResult("unknown", {}, false, "Operation entries must be tables", nil, nil, nil, nil))
                        failureCount += 1
                        continue
                end

                local action = operation.action
                local processor = PROCESSORS[action]
                if not processor then
                        table.insert(results, makeResult(action or "unknown", normalisePath(operation.path or {}), false, string.format("Unsupported ManageScripts action '%s'", tostring(action)), nil, nil, nil, nil))
                        failureCount += 1
                        continue
                end

                local metadataRequest = mergeMetadataSelection(defaultMetadata, operation.metadata)
                local result = processor(operation :: any, metadataRequest)
                table.insert(results, result)
                if result.success then
                        successCount += 1
                else
                        failureCount += 1
                end
        end

        local total = successCount + failureCount
        local summary = string.format(
                "Processed %d script operations (%d succeeded, %d failed)",
                total,
                successCount,
                failureCount
        )

        local response: ManageScriptsResponse = {
                results = results,
                summary = summary,
        }

        return HttpService:JSONEncode(response)
end

return handleManageScripts :: Types.ToolFunction
