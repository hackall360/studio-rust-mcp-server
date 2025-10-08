local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")
local SelectionService = game:GetService("Selection")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local function logAction(action: string, message: string)
        print(string.format("[MCP][EditorSessionControl] %s - %s", action, message))
end

local function normalisePath(path: Types.InstancePath): { string }
        local segments = {}
        if type(path) ~= "table" then
                return segments
        end

        for _, segment in path do
                if typeof(segment) == "string" and segment ~= "" and segment ~= "game" and segment ~= "DataModel" then
                        table.insert(segments, segment)
                end
        end

        return segments
end

local function resolveInstance(path: Types.InstancePath): (Instance?, { string }, string?)
        local segments = normalisePath(path)
        local current: Instance = game

        for _, segment in segments do
                local child = current:FindFirstChild(segment)
                if not child then
                        local parentName = if current == game then "game" else current:GetFullName()
                        return nil, segments, string.format("Unable to find '%s' under %s", segment, parentName)
                end
                current = child
        end

        return current, segments, nil
end

local function encodeResponse(response: Types.EditorSessionControlResponse): string
        return HttpService:JSONEncode(response)
end

local function toCFrame(components: Types.CFrameComponents?): (CFrame?, string?)
        if type(components) ~= "table" then
                return nil, "Expected an array of 12 numbers for CFrame components"
        end
        if #components ~= 12 then
                return nil, string.format("CFrame components must contain 12 numbers, received %d", #components)
        end

        local unpacked = table.create(12)
        for index = 1, 12 do
                local value = components[index]
                if typeof(value) ~= "number" then
                        return nil, string.format("CFrame component at index %d is not a number", index)
                end
                unpacked[index] = value
        end

        return CFrame.new(table.unpack(unpacked, 1, 12)), nil
end

local function setSelection(action: Types.EditorSessionSetSelectionAction): Types.EditorSessionControlResponse
        local resolved = {}
        local missing = {}

        for _, path in action.paths do
                local instance, segments, err = resolveInstance(path)
                if instance then
                        table.insert(resolved, instance)
                else
                        table.insert(missing, {
                                path = segments,
                                error = err,
                        })
                end
        end

        SelectionService:Set(resolved)

        local success = #missing == 0
        local message
        if success then
                        message = string.format("Selected %d instance(s)", #resolved)
        else
                        local missingSummaries = table.create(#missing)
                        for index, failure in missing do
                                local segments = failure.path
                                local err = failure.error or "Unknown error"
                                missingSummaries[index] = string.format("[%s] %s", table.concat(segments, "."), err)
                        end
                        message = "Selection updated with missing paths: " .. table.concat(missingSummaries, "; ")
        end

        logAction("set_selection", message)

        return {
                action = "set_selection",
                success = success,
                message = message,
                affectedInstances = #resolved,
        }
end

local function applyCameraTransforms(action: Types.EditorSessionFocusCameraAction): Types.EditorSessionControlResponse
        local camera = Workspace.CurrentCamera
        if not camera then
                local message = "CurrentCamera is unavailable"
                logAction("focus_camera", message)
                return {
                        action = "focus_camera",
                        success = false,
                        message = message,
                        affectedInstances = nil,
                }
        end

        local success = true
        local applied = {}
        local errors = {}

        if action.cframeComponents ~= nil then
                local newCFrame, err = toCFrame(action.cframeComponents)
                if newCFrame then
                        camera.CFrame = newCFrame
                        table.insert(applied, "CFrame")
                else
                        success = false
                        table.insert(errors, err)
                end
        end

        if action.focusComponents ~= nil then
                local newFocus, err = toCFrame(action.focusComponents)
                if newFocus then
                        camera.Focus = newFocus
                        table.insert(applied, "Focus")
                else
                        success = false
                        table.insert(errors, err)
                end
        end

        if action.fieldOfView ~= nil then
                local fieldOfView = tonumber(action.fieldOfView)
                if fieldOfView then
                        camera.FieldOfView = fieldOfView
                        table.insert(applied, string.format("FieldOfView=%.2f", fieldOfView))
                else
                        success = false
                        table.insert(errors, "fieldOfView must be numeric")
                end
        end

        local message
        if #applied > 0 then
                message = "Applied " .. table.concat(applied, ", ")
        else
                message = "No camera properties were updated"
        end

        if #errors > 0 then
                message ..= " (" .. table.concat(errors, "; ") .. ")"
        end

        logAction("focus_camera", message)

        return {
                action = "focus_camera",
                success = success and #errors == 0,
                message = message,
                affectedInstances = nil,
        }
end

local function accumulateBoundsForCFrame(currentMin: Vector3?, currentMax: Vector3?, transform: CFrame, size: Vector3)
        local halfSize = size * 0.5
        local corners = {
                Vector3.new(-halfSize.X, -halfSize.Y, -halfSize.Z),
                Vector3.new(halfSize.X, -halfSize.Y, -halfSize.Z),
                Vector3.new(-halfSize.X, halfSize.Y, -halfSize.Z),
                Vector3.new(halfSize.X, halfSize.Y, -halfSize.Z),
                Vector3.new(-halfSize.X, -halfSize.Y, halfSize.Z),
                Vector3.new(halfSize.X, -halfSize.Y, halfSize.Z),
                Vector3.new(-halfSize.X, halfSize.Y, halfSize.Z),
                Vector3.new(halfSize.X, halfSize.Y, halfSize.Z),
        }

        for _, offset in corners do
                local worldPoint = transform:PointToWorldSpace(offset)
                if currentMin == nil then
                        currentMin = worldPoint
                        currentMax = worldPoint
                else
                        currentMin = Vector3.new(
                                math.min(currentMin.X, worldPoint.X),
                                math.min(currentMin.Y, worldPoint.Y),
                                math.min(currentMin.Z, worldPoint.Z)
                        )
                        currentMax = Vector3.new(
                                math.max(currentMax.X, worldPoint.X),
                                math.max(currentMax.Y, worldPoint.Y),
                                math.max(currentMax.Z, worldPoint.Z)
                        )
                end
        end

        return currentMin, currentMax
end

local function gatherBoundingExtents(instances: { Instance }): (Vector3?, Vector3?)
        local minBound: Vector3?
        local maxBound: Vector3?

        for _, instance in instances do
                if instance:IsA("BasePart") then
                        minBound, maxBound = accumulateBoundsForCFrame(minBound, maxBound, instance.CFrame, instance.Size)
                else
                        local ok, cframe, size = pcall(function()
                                return (instance :: any):GetBoundingBox()
                        end)
                        if ok and typeof(cframe) == "CFrame" and typeof(size) == "Vector3" then
                                minBound, maxBound = accumulateBoundsForCFrame(minBound, maxBound, cframe :: CFrame, size :: Vector3)
                        else
                                local okPivot, pivot = pcall(function()
                                        return (instance :: any):GetPivot()
                                end)
                                if okPivot and typeof(pivot) == "CFrame" then
                                        minBound, maxBound = accumulateBoundsForCFrame(minBound, maxBound, pivot :: CFrame, Vector3.zero)
                                end
                        end
                end
        end

        return minBound, maxBound
end

local function frameInstances(action: Types.EditorSessionFrameInstancesAction): Types.EditorSessionControlResponse
        local resolved = {}
        for _, path in action.paths do
                local instance, _segments, _err = resolveInstance(path)
                if instance then
                        table.insert(resolved, instance)
                end
        end

        if #resolved == 0 then
                local message = "No instances resolved for framing"
                logAction("frame_instances", message)
                return {
                        action = "frame_instances",
                        success = false,
                        message = message,
                        affectedInstances = 0,
                }
        end

        local camera = Workspace.CurrentCamera
        if not camera then
                local message = "CurrentCamera is unavailable"
                logAction("frame_instances", message)
                return {
                        action = "frame_instances",
                        success = false,
                        message = message,
                        affectedInstances = 0,
                }
        end

        local minBound, maxBound = gatherBoundingExtents(resolved)
        if not minBound or not maxBound then
                local message = "Unable to compute bounds for the provided instances"
                logAction("frame_instances", message)
                return {
                        action = "frame_instances",
                        success = false,
                        message = message,
                        affectedInstances = #resolved,
                }
        end

        local center = (minBound + maxBound) * 0.5
        local extents = maxBound - minBound
        local radius = extents.Magnitude * 0.5
        local fieldOfView = math.rad(camera.FieldOfView)
        if fieldOfView <= 0 then
                fieldOfView = math.rad(70)
        end

        local distance = radius / math.tan(fieldOfView / 2)
        if not distance or distance ~= distance then
                distance = radius
        end
        distance = math.max(distance, radius + 1)

        local lookVector = camera.CFrame.LookVector
        if lookVector.Magnitude < 1e-3 then
                lookVector = Vector3.new(0, 0, -1)
        end
        local targetPosition = center - lookVector.Unit * distance
        local targetFocus = CFrame.new(center)
        local targetCFrame = CFrame.new(targetPosition, center)

        local tweenSeconds = action.tweenSeconds
        if typeof(tweenSeconds) == "number" and tweenSeconds > 0 then
                local tweenInfo = TweenInfo.new(tweenSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
                local cameraTween = TweenService:Create(camera, tweenInfo, {
                        CFrame = targetCFrame,
                        Focus = targetFocus,
                })
                cameraTween:Play()
        else
                camera.CFrame = targetCFrame
                camera.Focus = targetFocus
        end

        local message = string.format("Framed %d instance(s)", #resolved)
        logAction("frame_instances", message)

        return {
                action = "frame_instances",
                success = true,
                message = message,
                affectedInstances = #resolved,
        }
end

local function openScript(action: Types.EditorSessionOpenScriptAction): Types.EditorSessionControlResponse
        local scriptInstance, segments, err = resolveInstance(action.path)
        if not scriptInstance then
                local message = err or "Unable to resolve script path"
                logAction("open_script", message)
                return {
                        action = "open_script",
                        success = false,
                        message = message,
                        affectedInstances = nil,
                }
        end

        if not scriptInstance:IsA("LuaSourceContainer") then
                local message = string.format("%s is not a script", scriptInstance:GetFullName())
                logAction("open_script", message)
                return {
                        action = "open_script",
                        success = false,
                        message = message,
                        affectedInstances = nil,
                }
        end

        if not plugin then
                local message = "Plugin context is unavailable"
                logAction("open_script", message)
                return {
                        action = "open_script",
                        success = false,
                        message = message,
                        affectedInstances = nil,
                }
        end

        local okOpen, openError = pcall(function()
                if action.line ~= nil then
                        plugin:OpenScript(scriptInstance, action.line)
                else
                        plugin:OpenScript(scriptInstance)
                end
        end)

        if not okOpen then
                local message = "Failed to open script: " .. tostring(openError)
                logAction("open_script", message)
                return {
                        action = "open_script",
                        success = false,
                        message = message,
                        affectedInstances = nil,
                }
        end

        local document
        if plugin.OpenScriptDocument then
                local okDoc, docOrError = pcall(function()
                        return plugin:OpenScriptDocument(scriptInstance)
                end)
                if okDoc then
                        document = docOrError
                else
                        warn("[MCP][EditorSessionControl] Failed to acquire ScriptDocument: " .. tostring(docOrError))
                end
        end

        if document then
                if action.line ~= nil then
                        local line = math.max(1, math.floor(action.line))
                        local column = if action.column ~= nil then math.max(0, math.floor(action.column)) else 0
                        if document.SetCursorPosition then
                                document:SetCursorPosition(line, column)
                        end
                        if document.SetSelection then
                                document:SetSelection(line, column, line, column)
                        end
                end

                if action.focus and document.Focus then
                        document:Focus()
                end
        elseif action.focus then
                local okFocus, focusError = pcall(function()
                        plugin:OpenScript(scriptInstance)
                end)
                if not okFocus then
                        warn("[MCP][EditorSessionControl] Unable to refocus script tab: " .. tostring(focusError))
                end
        end

        local displaySegments = table.concat(segments, ".")
        if displaySegments == "" then
                displaySegments = scriptInstance:GetFullName()
        end

        local message = string.format("Opened %s", displaySegments)
        if action.line ~= nil then
                message ..= string.format(" at line %d", action.line)
                if action.column ~= nil then
                        message ..= string.format(":%d", action.column)
                end
        end

        logAction("open_script", message)

        return {
                action = "open_script",
                success = true,
                message = message,
                affectedInstances = nil,
        }
end

local function handleEditorSessionControl(args: Types.ToolArgs): string?
        if args.tool ~= "EditorSessionControl" then
                return nil
        end

        local params = args.params
        if type(params) ~= "table" then
                error("Missing params in EditorSessionControl payload")
        end

        local action = params.action
        if action == "set_selection" then
                return encodeResponse(setSelection(params :: Types.EditorSessionSetSelectionAction))
        elseif action == "focus_camera" then
                return encodeResponse(applyCameraTransforms(params :: Types.EditorSessionFocusCameraAction))
        elseif action == "frame_instances" then
                return encodeResponse(frameInstances(params :: Types.EditorSessionFrameInstancesAction))
        elseif action == "open_script" then
                return encodeResponse(openScript(params :: Types.EditorSessionOpenScriptAction))
        end

        error("Unsupported EditorSessionControl action: " .. tostring(action))
end

return handleEditorSessionControl :: Types.ToolFunction
