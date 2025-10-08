local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local StudioService = game:GetService("StudioService")
local TestService = game:GetService("TestService")

local okVirtualInputManager, VirtualInputManager = pcall(function()
        return game:GetService("VirtualInputManager")
end)
if not okVirtualInputManager then
        VirtualInputManager = nil
end

export type TestAndPlayControlArgs = Types.TestAndPlayControlArgs
export type TestAndPlayControlOptions = Types.TestAndPlayControlOptions
export type TestAndPlayInputStep = Types.TestAndPlayInputStep
export type TestAndPlayTelemetryFlags = Types.TestAndPlayTelemetryFlags

local function cloneStringArray(values: { any }?): { string }
        local result = {}
        if type(values) ~= "table" then
                return result
        end

        for _, value in values do
                if typeof(value) == "string" and value ~= "" then
                        table.insert(result, value)
                end
        end

        return result
end

local function sanitizeDelaySeconds(value: any): number?
        if typeof(value) ~= "number" then
                return nil
        end
        if value < 0 then
                return 0
        end
        if value == value then
                return value
        end
        return nil
end

local function sanitizeInputStep(step: any): TestAndPlayInputStep?
        if type(step) ~= "table" then
                return nil
        end

        local kind = step.kind
        if typeof(kind) ~= "string" then
                return nil
        end

        if kind == "wait" then
                if typeof(step.seconds) ~= "number" then
                        return nil
                end
                local seconds = math.max(0, step.seconds)
                return {
                        kind = "wait",
                        seconds = seconds,
                }
        elseif kind == "key" then
                if typeof(step.keyCode) ~= "string" or step.keyCode == "" then
                        return nil
                end
                local sanitized: TestAndPlayInputStep = {
                        kind = "key",
                        keyCode = step.keyCode,
                }
                if typeof(step.isDown) == "boolean" then
                        sanitized.isDown = step.isDown
                end
                if typeof(step.isRepeat) == "boolean" then
                        sanitized.isRepeat = step.isRepeat
                end
                if typeof(step.text) == "string" and step.text ~= "" then
                        sanitized.text = step.text
                end
                local delay = sanitizeDelaySeconds(step.delaySeconds)
                if delay then
                        sanitized.delaySeconds = delay
                end
                return sanitized
        elseif kind == "mouse_button" then
                if typeof(step.button) ~= "string" or step.button == "" then
                        return nil
                end
                local sanitized: TestAndPlayInputStep = {
                        kind = "mouse_button",
                        button = step.button,
                }
                if typeof(step.x) == "number" then
                        sanitized.x = step.x
                end
                if typeof(step.y) == "number" then
                        sanitized.y = step.y
                end
                if typeof(step.isDown) == "boolean" then
                        sanitized.isDown = step.isDown
                end
                if typeof(step.moveMouse) == "boolean" then
                        sanitized.moveMouse = step.moveMouse
                end
                local delay = sanitizeDelaySeconds(step.delaySeconds)
                if delay then
                        sanitized.delaySeconds = delay
                end
                return sanitized
        elseif kind == "mouse_move" then
                local sanitized: TestAndPlayInputStep = {
                        kind = "mouse_move",
                }
                if typeof(step.x) == "number" then
                        sanitized.x = step.x
                end
                if typeof(step.y) == "number" then
                        sanitized.y = step.y
                end
                if typeof(step.deltaX) == "number" then
                        sanitized.deltaX = step.deltaX
                end
                if typeof(step.deltaY) == "number" then
                        sanitized.deltaY = step.deltaY
                end
                local delay = sanitizeDelaySeconds(step.delaySeconds)
                if delay then
                        sanitized.delaySeconds = delay
                end
                if sanitized.x == nil then
                        sanitized.x = 0
                end
                if sanitized.y == nil then
                        sanitized.y = 0
                end
                if sanitized.deltaX == nil then
                        sanitized.deltaX = 0
                end
                if sanitized.deltaY == nil then
                        sanitized.deltaY = 0
                end
                return sanitized
        end

        return nil
end

local function sanitizeInputSequence(sequence: { any }?): { TestAndPlayInputStep }?
        if type(sequence) ~= "table" then
                return nil
        end

        local sanitized = {}
        for _, step in sequence do
                local sanitizedStep = sanitizeInputStep(step)
                if sanitizedStep then
                        table.insert(sanitized, sanitizedStep)
                end
        end

        if #sanitized == 0 then
                return nil
        end

        return sanitized
end

local function sanitizeTelemetryFlags(telemetry: any): TestAndPlayTelemetryFlags?
        if type(telemetry) ~= "table" then
                return nil
        end

        local sanitized: TestAndPlayTelemetryFlags = {}
        if typeof(telemetry.includeRunState) == "boolean" then
                sanitized.includeRunState = telemetry.includeRunState
        end
        if typeof(telemetry.includeLocalPlayerPosition) == "boolean" then
                sanitized.includeLocalPlayerPosition = telemetry.includeLocalPlayerPosition
        end
        if typeof(telemetry.includeGuiVisibility) == "boolean" then
                sanitized.includeGuiVisibility = telemetry.includeGuiVisibility
        end

        if next(sanitized) == nil then
                return nil
        end

        return sanitized
end

local function sanitizeOptions(options: TestAndPlayControlOptions?): TestAndPlayControlOptions?
        if type(options) ~= "table" then
                return nil
        end

        local sanitized: TestAndPlayControlOptions = {}
        if typeof(options.timeoutSeconds) == "number" then
                sanitized.timeoutSeconds = options.timeoutSeconds
        end
        if typeof(options.pollIntervalSeconds) == "number" then
                sanitized.pollIntervalSeconds = options.pollIntervalSeconds
        end
        local testNames = cloneStringArray(options.testNames)
        if #testNames > 0 then
                sanitized.testNames = testNames
        end
        if typeof(options.runAsync) == "boolean" then
                sanitized.runAsync = options.runAsync
        end
        if typeof(options.includeLogHistory) == "boolean" then
                sanitized.includeLogHistory = options.includeLogHistory
        end
        local inputSequence = sanitizeInputSequence(options.inputSequence)
        if inputSequence then
                sanitized.inputSequence = inputSequence
        end
        local watchTargets = cloneStringArray(options.watchTargets)
        if #watchTargets > 0 then
                sanitized.watchTargets = watchTargets
        end
        local telemetry = sanitizeTelemetryFlags(options.telemetry)
        if telemetry then
                sanitized.telemetry = telemetry
        end

        if next(sanitized) == nil then
                return nil
        end

        return sanitized
end

local function findUnknownOptions(options: TestAndPlayControlOptions?): { string }?
        if type(options) ~= "table" then
                return nil
        end

        local recognised = {
                timeoutSeconds = true,
                pollIntervalSeconds = true,
                testNames = true,
                runAsync = true,
                includeLogHistory = true,
                inputSequence = true,
                watchTargets = true,
                telemetry = true,
        }

        local unknown = {}
        for key, _ in options do
                if typeof(key) == "string" and not recognised[key] then
                        table.insert(unknown, key)
                end
        end

        if type(options.telemetry) == "table" then
                local recognisedTelemetry = {
                        includeRunState = true,
                        includeLocalPlayerPosition = true,
                        includeGuiVisibility = true,
                }
                for key, _ in options.telemetry do
                        if typeof(key) == "string" and not recognisedTelemetry[key] then
                                table.insert(unknown, "telemetry." .. key)
                        end
                end
        end

        if #unknown == 0 then
                return nil
        end

        table.sort(unknown)
        return unknown
end

local function sanitizeForJson(value: any, depth: number?): any
        local currentDepth = depth or 0
        if currentDepth >= 4 then
                return tostring(value)
        end

        local valueType = typeof(value)
        if valueType == "string" or valueType == "number" or valueType == "boolean" then
                return value
        elseif valueType == "table" then
                local isArray = true
                local highestIndex = 0
                for key, _ in value do
                        if typeof(key) ~= "number" then
                                isArray = false
                                break
                        end
                        if key > highestIndex then
                                highestIndex = key
                        end
                end

                if isArray then
                        local newArray = table.create(highestIndex)
                        for index = 1, highestIndex do
                                newArray[index] = sanitizeForJson(value[index], currentDepth + 1)
                        end
                        return newArray
                else
                        local newMap = {}
                        for key, item in value do
                                newMap[tostring(key)] = sanitizeForJson(item, currentDepth + 1)
                        end
                        return newMap
                end
        elseif valueType == "EnumItem" then
                return value.Name
        elseif valueType == "Instance" then
                local ok, fullName = pcall(function()
                        return value:GetFullName()
                end)
                if ok then
                        return fullName
                end
                return value.ClassName
        end

        return tostring(value)
end

local function createLogCollector()
        local buffer = {}
        local lastIndex = 1
        local connection: RBXScriptConnection? = nil
        local errorMessage: string? = nil

        local ok, err = pcall(function()
                connection = LogService.MessageOut:Connect(function(message: string, messageType)
                        local entry = {
                                message = tostring(message),
                                level = if typeof(messageType) == "EnumItem"
                                        then messageType.Name
                                        else tostring(messageType),
                                timestamp = os.clock(),
                        }
                        table.insert(buffer, entry)
                end)
        end)
        if not ok then
                errorMessage = tostring(err)
        end

        local collector = {}

        function collector.getAll()
                local copy = table.create(#buffer)
                for index = 1, #buffer do
                        copy[index] = buffer[index]
                end
                return copy
        end

        function collector.getNew()
                if lastIndex > #buffer then
                        return nil
                end

                local newEntries = {}
                for index = lastIndex, #buffer do
                        newEntries[#newEntries + 1] = buffer[index]
                end
                lastIndex = #buffer + 1

                if #newEntries == 0 then
                        return nil
                end

                return newEntries
        end

        function collector.disconnect()
                if connection then
                        connection:Disconnect()
                        connection = nil
                end
        end

        collector.error = errorMessage

        return collector
end

local function appendChunk(result: { [string]: any }, chunkIndex: number, logs: { any }?): number
        if not logs or #logs == 0 then
                return chunkIndex
        end

        local chunk = {
                index = chunkIndex + 1,
                timestamp = os.clock(),
                logs = logs,
        }
        table.insert(result.chunks, chunk)
        return chunkIndex + 1
end

local function pushStatusUpdate(result: { [string]: any }, status: string)
        if status == "" then
                return
        end

        if not result.statusUpdates then
                result.statusUpdates = {}
        end

        local updates = result.statusUpdates
        local last = updates[#updates]
        if not last or last.status ~= status then
                table.insert(updates, {
                        timestamp = os.clock(),
                        status = status,
                })
        end
end

local function shouldIncludeLogs(options: TestAndPlayControlOptions?): boolean
        if options and typeof(options.includeLogHistory) == "boolean" then
                return options.includeLogHistory
        end
        return true
end

local function createBaseResult(action: string, options: TestAndPlayControlOptions?): { [string]: any }
        local result = {
                action = action,
                startedAt = os.time(),
                _startedClock = os.clock(),
                status = "pending",
                chunks = {},
                warnings = {},
                errors = {},
        }
        if options then
                result.options = options
        end
        return result
end

local function readRunServiceState(): (boolean, string?)
        local ok, state = pcall(function()
                return RunService:IsRunning()
        end)
        if ok then
                return state == true, nil
        end
        return false, tostring(state)
end

local function waitForRunLoop(timeoutSeconds: number): (boolean, string?, number)
        local timeout = math.max(0.1, timeoutSeconds)
        local startClock = os.clock()
        local deadline = startClock + timeout
        local lastError: string? = nil

        while os.clock() < deadline do
                local running, err = readRunServiceState()
                if err then
                        lastError = err
                end
                if running then
                        return true, nil, os.clock() - startClock
                end
                task.wait(0.1)
        end

        local running, err = readRunServiceState()
        if running then
                return true, nil, os.clock() - startClock
        end
        if err then
                lastError = err
        end
        return false, lastError, os.clock() - startClock
end

local function captureLocalPlayerPosition(): ({ x: number, y: number, z: number }?, string?)
        local player = Players.LocalPlayer
        if player == nil then
                return nil, "Players.LocalPlayer is nil"
        end

        local character = player.Character
        if character == nil then
                return nil, "LocalPlayer.Character is unavailable"
        end

        local humanoidRoot = character:FindFirstChild("HumanoidRootPart")
        local basePart = if humanoidRoot and humanoidRoot:IsA("BasePart")
                then humanoidRoot
                else nil

        if basePart == nil then
                local primary = character.PrimaryPart
                if primary and primary:IsA("BasePart") then
                        basePart = primary
                end
        end

        if basePart == nil then
                return nil, "HumanoidRootPart or PrimaryPart is missing"
        end

        local position = basePart.Position
        return {
                x = position.X,
                y = position.Y,
                z = position.Z,
        }, nil
end

local function splitWatchTargetPath(target: string): { string }
        local segments = {}
        for segment in string.gmatch(target, "[^%.]+") do
                table.insert(segments, segment)
        end
        return segments
end

local function resolveWatchTarget(target: string): (Instance?, string?, string?)
        if typeof(target) ~= "string" or target == "" then
                return nil, nil, "Target must be a non-empty string"
        end

        local segments = splitWatchTargetPath(target)
        if #segments == 0 then
                return nil, nil, "Unable to parse watch target"
        end

        local current: Instance? = game
        for index, segment in segments do
                local isLast = index == #segments
                if segment == "game" or segment == "Game" then
                        current = game
                        if isLast then
                                return current, nil, nil
                        end
                        continue
                end

                local nextInstance: Instance? = nil
                if current == game then
                        local okService, service = pcall(function()
                                return game:GetService(segment)
                        end)
                        if okService then
                                nextInstance = service
                        end
                end

                if nextInstance == nil and current then
                        nextInstance = current:FindFirstChild(segment)
                end

                if nextInstance == nil and current then
                        local ok, value = pcall(function()
                                return (current :: any)[segment]
                        end)
                        if ok and typeof(value) == "Instance" then
                                nextInstance = value
                        elseif ok and isLast then
                                return current, segment, nil
                        end
                end

                if nextInstance then
                        current = nextInstance
                        if isLast then
                                return current, nil, nil
                        end
                else
                        if isLast then
                                return current, segment, nil
                        end
                        return nil, nil, string.format("Unable to resolve segment '%s'", segment)
                end
        end

        return current, nil, nil
end

local function captureWatchTargetValue(target: string)
        local instance, propertyName, resolveError = resolveWatchTarget(target)
        if resolveError then
                return nil, nil, resolveError
        end
        if instance == nil then
                return nil, nil, string.format("Watch target '%s' could not be resolved", target)
        end

        local properties = {}
        if propertyName then
                        table.insert(properties, propertyName)
        end
        table.insert(properties, "Visible")
        table.insert(properties, "Enabled")

        for _, property in properties do
                local ok, value = pcall(function()
                        return (instance :: any)[property]
                end)
                if ok and value ~= nil then
                        return value, property, nil
                end
        end

        return nil, nil, string.format("Unable to read a visibility property from '%s'", target)
end

local function captureGuiVisibility(targets: { string }, warnings: { any }): { [string]: any }
        local visibility = {}
        for _, target in targets do
                local value, property, errorMessage = captureWatchTargetValue(target)
                if errorMessage then
                        table.insert(warnings, string.format("%s", errorMessage))
                elseif value ~= nil then
                        visibility[target] = {
                                property = property,
                                value = sanitizeForJson(value, 1),
                        }
                end
        end

        return visibility
end

local function collectTelemetrySnapshot(
        options: TestAndPlayControlOptions?,
        result: { [string]: any }
): { [string]: any }?
        if type(options) ~= "table" or type(options.telemetry) ~= "table" then
                return nil
        end

        local telemetry = {}
        local flags = options.telemetry :: TestAndPlayTelemetryFlags

        if flags.includeRunState == true then
                local runState = {}
                local running, runError = readRunServiceState()
                runState.isRunning = running
                if runError then
                        table.insert(result.warnings, "RunService:IsRunning failed: " .. runError)
                end
                local ok, mode = pcall(function()
                        return RunService:IsRunMode()
                end)
                if ok then
                        runState.isRunMode = mode and true or false
                else
                        table.insert(result.warnings, "RunService:IsRunMode failed: " .. tostring(mode))
                end
                telemetry.runState = runState
        end

        if flags.includeLocalPlayerPosition == true then
                local position, positionError = captureLocalPlayerPosition()
                if position then
                        telemetry.localPlayerPosition = position
                elseif positionError then
                        table.insert(result.warnings, "LocalPlayer position unavailable: " .. positionError)
                end
        end

        if flags.includeGuiVisibility == true then
                local watchTargets = options.watchTargets
                if type(watchTargets) == "table" and #watchTargets > 0 then
                        local visibility = captureGuiVisibility(watchTargets, result.warnings)
                        if next(visibility) ~= nil then
                                telemetry.guiVisibility = visibility
                        end
                else
                        table.insert(
                                result.warnings,
                                "No watchTargets provided for GUI visibility telemetry"
                        )
                end
        end

        if next(telemetry) == nil then
                return nil
        end

        return telemetry
end

local function executeInputSequence(
        sequence: { TestAndPlayInputStep },
        result: { [string]: any }
): { [string]: any }
        local reports = {}
        if type(sequence) ~= "table" then
                return reports
        end

        for index, step in sequence do
                if typeof(step) ~= "table" then
                        continue
                end

                if typeof((step :: any).delaySeconds) == "number" then
                        task.wait(math.max(0, (step :: any).delaySeconds))
                end

                if step.kind == "wait" then
                        local waitSeconds = math.max(0, step.seconds or 0)
                        if waitSeconds > 0 then
                                task.wait(waitSeconds)
                        end
                        table.insert(reports, {
                                index = index,
                                kind = step.kind,
                                status = "waited",
                                seconds = waitSeconds,
                        })
                elseif step.kind == "key" then
                        local keyCodeEnum = Enum.KeyCode[step.keyCode]
                        if not keyCodeEnum then
                                table.insert(result.warnings, string.format(
                                        "Unknown keyCode '%s' for step %d",
                                        tostring(step.keyCode),
                                        index
                                ))
                                table.insert(reports, {
                                        index = index,
                                        kind = step.kind,
                                        status = "skipped",
                                        reason = "unknown_key_code",
                                })
                        elseif not VirtualInputManager then
                                table.insert(result.warnings, "VirtualInputManager is unavailable")
                                table.insert(reports, {
                                        index = index,
                                        kind = step.kind,
                                        status = "skipped",
                                        reason = "virtual_input_unavailable",
                                })
                        else
                                local isDown = if typeof(step.isDown) == "boolean" then step.isDown else true
                                local isRepeat = step.isRepeat == true
                                local text = if typeof(step.text) == "string" then step.text else nil
                                local ok, err = pcall(function()
                                        VirtualInputManager:SendKeyEvent(isDown, keyCodeEnum, isRepeat, text)
                                end)
                                if ok then
                                        table.insert(reports, {
                                                index = index,
                                                kind = step.kind,
                                                status = "sent",
                                                isDown = isDown,
                                                isRepeat = isRepeat,
                                        })
                                else
                                        local message = tostring(err)
                                        table.insert(result.warnings, string.format(
                                                "SendKeyEvent failed at step %d: %s",
                                                index,
                                                message
                                        ))
                                        table.insert(reports, {
                                                index = index,
                                                kind = step.kind,
                                                status = "error",
                                                message = message,
                                        })
                                end
                        end
                elseif step.kind == "mouse_button" then
                        local userInput = Enum.UserInputType[step.button]
                        if not userInput then
                                table.insert(result.warnings, string.format(
                                        "Unknown mouse button '%s' for step %d",
                                        tostring(step.button),
                                        index
                                ))
                                table.insert(reports, {
                                        index = index,
                                        kind = step.kind,
                                        status = "skipped",
                                        reason = "unknown_button",
                                })
                        elseif not VirtualInputManager then
                                table.insert(result.warnings, "VirtualInputManager is unavailable")
                                table.insert(reports, {
                                        index = index,
                                        kind = step.kind,
                                        status = "skipped",
                                        reason = "virtual_input_unavailable",
                                })
                        else
                                local x = typeof(step.x) == "number" and step.x or 0
                                local y = typeof(step.y) == "number" and step.y or 0
                                local isDown = if typeof(step.isDown) == "boolean" then step.isDown else true
                                local moveMouse = step.moveMouse == true
                                local ok, err = pcall(function()
                                        VirtualInputManager:SendMouseButtonEvent(x, y, userInput, isDown, moveMouse)
                                end)
                                if ok then
                                        table.insert(reports, {
                                                index = index,
                                                kind = step.kind,
                                                status = "sent",
                                                isDown = isDown,
                                                button = step.button,
                                        })
                                else
                                        local message = tostring(err)
                                        table.insert(result.warnings, string.format(
                                                "SendMouseButtonEvent failed at step %d: %s",
                                                index,
                                                message
                                        ))
                                        table.insert(reports, {
                                                index = index,
                                                kind = step.kind,
                                                status = "error",
                                                message = message,
                                        })
                                end
                        end
                elseif step.kind == "mouse_move" then
                        if not VirtualInputManager then
                                table.insert(result.warnings, "VirtualInputManager is unavailable")
                                table.insert(reports, {
                                        index = index,
                                        kind = step.kind,
                                        status = "skipped",
                                        reason = "virtual_input_unavailable",
                                })
                        else
                                local x = typeof(step.x) == "number" and step.x or 0
                                local y = typeof(step.y) == "number" and step.y or 0
                                local deltaX = typeof(step.deltaX) == "number" and step.deltaX or 0
                                local deltaY = typeof(step.deltaY) == "number" and step.deltaY or 0
                                local ok, err = pcall(function()
                                        VirtualInputManager:SendMouseMoveEvent(x, y, deltaX, deltaY)
                                end)
                                if ok then
                                        table.insert(reports, {
                                                index = index,
                                                kind = step.kind,
                                                status = "sent",
                                                x = x,
                                                y = y,
                                        })
                                else
                                        local message = tostring(err)
                                        table.insert(result.warnings, string.format(
                                                "SendMouseMoveEvent failed at step %d: %s",
                                                index,
                                                message
                                        ))
                                        table.insert(reports, {
                                                index = index,
                                                kind = step.kind,
                                                status = "error",
                                                message = message,
                                        })
                                end
                        end
                else
                        table.insert(result.warnings, string.format(
                                "Unsupported input step kind '%s' at index %d",
                                tostring(step.kind),
                                index
                        ))
                end
        end

        return reports
end

local function tryStudioMethods(methods: { string }, ...): (boolean, string?, string?)
        local lastError: string? = nil
        for _, methodName in methods do
                local method = (StudioService :: any)[methodName]
                if typeof(method) == "function" then
                        local ok, value = pcall(method, StudioService, ...)
                        if ok then
                                return true, methodName, nil
                        end
                        lastError = tostring(value)
                else
                        lastError = string.format("StudioService does not expose %s", methodName)
                end
        end
        return false, nil, lastError
end

local function finalizeResult(
        result: { [string]: any },
        collector,
        chunkIndex: number,
        includeLogs: boolean
)
        if collector then
                chunkIndex = appendChunk(result, chunkIndex, collector.getNew())
                local allLogs = collector.getAll()
                collector.disconnect()
                if includeLogs and #allLogs > 0 then
                        result.logs = allLogs
                end
        end

        result.endedAt = os.time()
        result.durationSeconds = math.max(0, os.clock() - result._startedClock)
        result._startedClock = nil

        if result.chunks and #result.chunks == 0 then
                result.chunks = nil
        end
        if result.warnings and #result.warnings == 0 then
                result.warnings = nil
        end
        if result.errors and #result.errors == 0 then
                result.errors = nil
        end
        if result.statusUpdates and #result.statusUpdates == 0 then
                result.statusUpdates = nil
        end
        if not includeLogs then
                result.logs = nil
        elseif result.logs and #result.logs == 0 then
                result.logs = nil
        end
        if result.options and next(result.options) == nil then
                result.options = nil
        end
end

local function handlePlaySession(
        action: string,
        options: TestAndPlayControlOptions?,
        methodNames: { string },
        unknownOptions: { string }?
): string
        local result = createBaseResult(action, options)
        local includeLogs = shouldIncludeLogs(options)
        local collector = createLogCollector()
        local chunkIndex = 0

        if collector.error then
                table.insert(result.warnings, "Unable to subscribe to log output: " .. collector.error)
        end
        if unknownOptions then
                table.insert(result.warnings, "Ignoring unsupported option keys: " .. table.concat(unknownOptions, ", "))
        end

        local success, methodName, errorMessage = tryStudioMethods(methodNames)
        if not success then
                result.status = "error"
                table.insert(result.errors, {
                        stage = "start",
                        message = errorMessage or "Unknown StudioService error",
                })
                finalizeResult(result, collector, chunkIndex, includeLogs)
                return HttpService:JSONEncode(result)
        end

        result.method = methodName
        result.status = "starting"
        pushStatusUpdate(result, result.status)

        local timeout = if options and typeof(options.timeoutSeconds) == "number"
                then math.max(0.1, options.timeoutSeconds)
                else 120
        local pollInterval = if options and typeof(options.pollIntervalSeconds) == "number"
                then math.max(0.1, options.pollIntervalSeconds)
                else 0.5

        local startedRunning = false
        local timedOut = false

        while true do
                local logs = collector.getNew()
                if logs then
                        chunkIndex = appendChunk(result, chunkIndex, logs)
                end

                local isRunning, runError = readRunServiceState()
                if runError then
                        table.insert(result.warnings, "RunService:IsRunning failed: " .. runError)
                end

                if isRunning then
                        if not startedRunning then
                                startedRunning = true
                                result.status = "running"
                                pushStatusUpdate(result, result.status)
                        end
                elseif startedRunning then
                        result.status = "completed"
                        pushStatusUpdate(result, result.status)
                        break
                end

                local elapsed = os.clock() - result._startedClock
                if elapsed >= timeout then
                        timedOut = true
                        if startedRunning then
                                result.status = "timeout"
                                table.insert(result.errors, {
                                        stage = "watchdog",
                                        message = string.format("Session exceeded %.2f seconds", timeout),
                                })
                        else
                                result.status = "failed_to_start"
                                table.insert(result.errors, {
                                        stage = "start",
                                        message = string.format("Session did not begin within %.2f seconds", timeout),
                                })
                        end
                        pushStatusUpdate(result, result.status)
                        break
                end

                task.wait(pollInterval)
        end

        result.sessionStarted = startedRunning
        result.sessionTimedOut = timedOut
        local finalState, finalError = readRunServiceState()
        result.isRunning = finalState
        if finalError then
                table.insert(result.warnings, "Final RunService:IsRunning check failed: " .. finalError)
        end

        pushStatusUpdate(result, result.status)

        finalizeResult(result, collector, chunkIndex, includeLogs)
        return HttpService:JSONEncode(result)
end

local function readTestServiceRunningState(runCompleted: boolean): (boolean, string?)
        local ok, state = pcall(function()
                local member = (TestService :: any).IsRunning
                if typeof(member) == "function" then
                        return member(TestService)
                end
                return member
        end)
        if ok then
                if state == nil then
                        return not runCompleted, nil
                end
                if typeof(state) == "boolean" then
                        return state, nil
                end
                return state and true or false, nil
        end
        return not runCompleted, tostring(state)
end

local function readTestServiceStatus(): (string?, string?)
        local ok, value = pcall(function()
                local member = (TestService :: any).GetStatus
                if typeof(member) == "function" then
                        return member(TestService)
                end
                local statusValue = (TestService :: any).Status
                if statusValue ~= nil then
                        return statusValue
                end
                return nil
        end)
        if ok then
                if value == nil then
                        return nil, nil
                end
                return tostring(value), nil
        end
        return nil, tostring(value)
end

local function serializeErrorEntry(entry: any): any
        if type(entry) == "table" then
                local sanitized = {}
                for key, value in entry do
                        if typeof(value) == "string" or typeof(value) == "number" or typeof(value) == "boolean" then
                                sanitized[key] = value
                        elseif key == "stackTrace" or key == "StackTrace" then
                                sanitized.stackTrace = tostring(value)
                        elseif key == "message" or key == "Message" then
                                sanitized.message = tostring(value)
                        end
                end
                if next(sanitized) == nil then
                        return tostring(entry)
                end
                return sanitized
        end
        return tostring(entry)
end

local function gatherTestServiceSummary(): { [string]: any }
        local summary = {}

        local function captureProperty(targetKey, propertyNames)
                for _, propertyName in propertyNames do
                        local ok, value = pcall(function()
                                return (TestService :: any)[propertyName]
                        end)
                        if ok and value ~= nil then
                                if typeof(value) == "number" then
                                        summary[targetKey] = value
                                elseif typeof(value) == "string" then
                                        summary[targetKey] = tonumber(value) or value
                                else
                                        summary[targetKey] = sanitizeForJson(value, 1)
                                end
                                return
                        end
                end
        end

        captureProperty("testCount", { "TestCount", "TestsRun" })
        captureProperty("successCount", { "SuccessCount", "PassCount" })
        captureProperty("warningCount", { "WarnCount", "WarningCount" })
        captureProperty("errorCount", { "ErrorCount", "Errors" })

        local status, statusError = readTestServiceStatus()
        if status then
                summary.status = status
        elseif statusError then
                summary.statusError = statusError
        end

        local okErrors, errors = pcall(function()
                local getter = (TestService :: any).GetErrors
                if typeof(getter) == "function" then
                        return getter(TestService)
                end
                return nil
        end)
        if okErrors and type(errors) == "table" then
                local serializedErrors = {}
                for _, entry in errors do
                        serializedErrors[#serializedErrors + 1] = serializeErrorEntry(entry)
                end
                if #serializedErrors > 0 then
                        summary.errors = serializedErrors
                end
        end

        local okResults, results = pcall(function()
                local getter = (TestService :: any).GetResults
                if typeof(getter) == "function" then
                        return getter(TestService)
                end
                return nil
        end)
        if okResults and type(results) == "table" then
                summary.results = sanitizeForJson(results, 0)
        end

        return summary
end

local function stopTestService()
        local stopper = (TestService :: any).Stop
        if typeof(stopper) == "function" then
                stopper(TestService)
        end
end

local function handleRunTests(
        options: TestAndPlayControlOptions?,
        unknownOptions: { string }?
): string
        local result = createBaseResult("run_tests", options)
        local includeLogs = shouldIncludeLogs(options)
        local collector = createLogCollector()
        local chunkIndex = 0

        if collector.error then
                table.insert(result.warnings, "Unable to subscribe to log output: " .. collector.error)
        end
        if unknownOptions then
                table.insert(result.warnings, "Ignoring unsupported option keys: " .. table.concat(unknownOptions, ", "))
        end

        local runAsync = options and options.runAsync == true
        local testNames = if options and options.testNames then options.testNames else nil

        local runError: string? = nil
        local runCompleted = false
        task.spawn(function()
                local ok, err = pcall(function()
                        if runAsync and typeof((TestService :: any).RunAsync) == "function" then
                                (TestService :: any).RunAsync(TestService)
                        elseif testNames and #testNames > 0 and typeof((TestService :: any).Run) == "function" then
                                (TestService :: any).Run(TestService, testNames)
                        else
                                TestService:Run()
                        end
                end)
                if not ok then
                        runError = tostring(err)
                end
                runCompleted = true
        end)

        local timeout = if options and typeof(options.timeoutSeconds) == "number"
                then math.max(0.1, options.timeoutSeconds)
                else 180
        local pollInterval = if options and typeof(options.pollIntervalSeconds) == "number"
                then math.max(0.05, options.pollIntervalSeconds)
                else 0.5

        local startClock = os.clock()
        pushStatusUpdate(result, "starting")
        local lastStatus: string? = nil

        while true do
                local logs = collector.getNew()
                if logs then
                        chunkIndex = appendChunk(result, chunkIndex, logs)
                end

                local status, statusError = readTestServiceStatus()
                if status then
                        if status ~= lastStatus then
                                lastStatus = status
                                pushStatusUpdate(result, status)
                        end
                elseif statusError then
                        table.insert(result.warnings, "TestService status unavailable: " .. statusError)
                end

                local isRunning, runningError = readTestServiceRunningState(runCompleted)
                if runningError then
                                table.insert(result.warnings, "TestService:IsRunning failed: " .. runningError)
                end

                if not isRunning and runCompleted then
                        result.status = "completed"
                        break
                end

                if runError then
                        result.status = "error"
                        table.insert(result.errors, {
                                stage = "execution",
                                message = runError,
                        })
                        pushStatusUpdate(result, result.status)
                        break
                end

                local elapsed = os.clock() - startClock
                if elapsed >= timeout then
                        result.status = "timeout"
                        table.insert(result.errors, {
                                stage = "watchdog",
                                message = string.format("Test run exceeded %.2f seconds", timeout),
                        })
                        local okStop, stopErr = pcall(stopTestService)
                        if not okStop then
                                table.insert(result.warnings, "Failed to stop TestService: " .. tostring(stopErr))
                        end
                        pushStatusUpdate(result, result.status)
                        break
                end

                result.status = "running"
                pushStatusUpdate(result, result.status)
                task.wait(pollInterval)
        end

        local summary = gatherTestServiceSummary()
        if next(summary) ~= nil then
                result.summary = summary
                if result.status == "completed" then
                        local errorCount = typeof(summary.errorCount) == "number" and summary.errorCount or 0
                        local warningCount = typeof(summary.warningCount) == "number" and summary.warningCount or 0
                        if errorCount > 0 then
                                result.status = "failed"
                                pushStatusUpdate(result, result.status)
                        elseif warningCount > 0 then
                                result.status = "completed_with_warnings"
                                pushStatusUpdate(result, result.status)
                        end
                end
        end

        pushStatusUpdate(result, result.status)

        finalizeResult(result, collector, chunkIndex, includeLogs)
        return HttpService:JSONEncode(result)
end

local function handleStop(
        options: TestAndPlayControlOptions?,
        unknownOptions: { string }?
): string
        local result = createBaseResult("stop", options)
        local includeLogs = shouldIncludeLogs(options)
        local collector = createLogCollector()
        local chunkIndex = 0

        if collector.error then
                table.insert(result.warnings, "Unable to subscribe to log output: " .. collector.error)
        end
        if unknownOptions then
                table.insert(result.warnings, "Ignoring unsupported option keys: " .. table.concat(unknownOptions, ", "))
        end

        local wasRunning, runError = readRunServiceState()
        result.wasRunning = wasRunning
        if runError then
                table.insert(result.warnings, "RunService:IsRunning failed: " .. runError)
        end

        pushStatusUpdate(result, "stopping")

        local stopErrors = {}
        local okStopRun, stopRunError = pcall(function()
                RunService:Stop()
        end)
        if not okStopRun then
                table.insert(stopErrors, tostring(stopRunError))
        end

        local studioStopped, methodName, studioError = tryStudioMethods({ "StopPluginPlay", "StopPlay" })
        if studioStopped and methodName then
                result.method = methodName
        elseif studioError then
                table.insert(stopErrors, studioError)
        end

        local logs = collector.getNew()
        if logs then
                chunkIndex = appendChunk(result, chunkIndex, logs)
        end

        task.wait(0.1)
        local isRunning, finalRunError = readRunServiceState()
        result.isRunning = isRunning
        if finalRunError then
                table.insert(result.warnings, "Final RunService:IsRunning check failed: " .. finalRunError)
        end

        if #stopErrors > 0 then
                result.status = "partial"
                for _, message in stopErrors do
                        table.insert(result.errors, {
                                stage = "stop",
                                message = message,
                        })
                end
        else
                result.status = if wasRunning then "stopped" else "idle"
        end

        pushStatusUpdate(result, result.status)

        finalizeResult(result, collector, chunkIndex, includeLogs)
        return HttpService:JSONEncode(result)
end

local function handleSendInput(
        options: TestAndPlayControlOptions?,
        unknownOptions: { string }?
): string
        local result = createBaseResult("send_input", options)
        local includeLogs = shouldIncludeLogs(options)
        local collector = createLogCollector()
        local chunkIndex = 0

        if collector.error then
                table.insert(result.warnings, "Unable to subscribe to log output: " .. collector.error)
        end
        if unknownOptions then
                table.insert(result.warnings, "Ignoring unsupported option keys: " .. table.concat(unknownOptions, ", "))
        end

        if not VirtualInputManager then
                result.status = "error"
                table.insert(result.errors, {
                        stage = "preflight",
                        message = "VirtualInputManager service is unavailable in this session",
                })
                pushStatusUpdate(result, result.status)
                finalizeResult(result, collector, chunkIndex, includeLogs)
                return HttpService:JSONEncode(result)
        end

        local sequence = nil
        if options and type(options.inputSequence) == "table" then
                sequence = options.inputSequence
        end
        if not sequence or #sequence == 0 then
                result.status = "skipped"
                table.insert(
                        result.warnings,
                        "No inputSequence steps were provided; nothing was sent to the session"
                )
                pushStatusUpdate(result, result.status)
                finalizeResult(result, collector, chunkIndex, includeLogs)
                return HttpService:JSONEncode(result)
        end

        local timeout = if options and typeof(options.timeoutSeconds) == "number"
                then options.timeoutSeconds
                else 30
        local running, runError, waitedSeconds = waitForRunLoop(timeout)
        result.waitedForRunSeconds = waitedSeconds
        if not running then
                result.status = "not_running"
                local message = "RunService was not running; input sequence aborted"
                if runError then
                        message ..= ": " .. runError
                end
                table.insert(result.errors, {
                        stage = "preflight",
                        message = message,
                })
                pushStatusUpdate(result, result.status)
                finalizeResult(result, collector, chunkIndex, includeLogs)
                return HttpService:JSONEncode(result)
        end

        result.status = "sending"
        pushStatusUpdate(result, result.status)

        local reports = executeInputSequence(sequence, result)
        result.inputReport = reports
        result.sequenceLength = #sequence

        local telemetry = collectTelemetrySnapshot(options, result)
        if telemetry then
                result.telemetry = telemetry
        end

        local isRunning, finalRunError = readRunServiceState()
        result.isRunning = isRunning
        if finalRunError then
                table.insert(result.warnings, "Final RunService:IsRunning check failed: " .. finalRunError)
        end

        result.status = "completed"
        pushStatusUpdate(result, result.status)

        finalizeResult(result, collector, chunkIndex, includeLogs)
        return HttpService:JSONEncode(result)
end

local function handleCaptureStats(
        options: TestAndPlayControlOptions?,
        unknownOptions: { string }?
): string
        local result = createBaseResult("capture_stats", options)
        if unknownOptions then
                table.insert(result.warnings, "Ignoring unsupported option keys: " .. table.concat(unknownOptions, ", "))
        end

        result.status = "collecting"
        pushStatusUpdate(result, result.status)

        local telemetry = collectTelemetrySnapshot(options, result)
        if telemetry then
                result.telemetry = telemetry
        else
                table.insert(
                        result.warnings,
                        "No telemetry flags were provided; returning run state details only"
                )
        end

        local isRunning, runError = readRunServiceState()
        result.isRunning = isRunning
        if runError then
                table.insert(result.warnings, "RunService:IsRunning failed: " .. runError)
        end

        result.status = "completed"
        pushStatusUpdate(result, result.status)

        finalizeResult(result, nil, 0, shouldIncludeLogs(options))
        return HttpService:JSONEncode(result)
end

local function handleTestAndPlayControl(args: Types.ToolArgs): string?
        if args.tool ~= "TestAndPlayControl" then
                return nil
        end

        local params = args.params :: TestAndPlayControlArgs
        if type(params) ~= "table" then
                error("Missing params in TestAndPlayControl payload")
        end

        local action = params.action
        if typeof(action) ~= "string" then
                error("Missing action in TestAndPlayControl payload")
        end

        local options = sanitizeOptions(params.options)
        local unknownOptions = findUnknownOptions(params.options)

        if action == "play_solo" then
                return handlePlaySession("play_solo", options, { "StartPlaySolo" }, unknownOptions)
        elseif action == "run_playtest" then
                return handlePlaySession(
                        "run_playtest",
                        options,
                        { "StartPlayLocal", "StartPlay", "StartPlaySolo" },
                        unknownOptions
                )
        elseif action == "run_tests" then
                return handleRunTests(options, unknownOptions)
        elseif action == "stop" then
                return handleStop(options, unknownOptions)
        elseif action == "send_input" then
                return handleSendInput(options, unknownOptions)
        elseif action == "capture_stats" then
                return handleCaptureStats(options, unknownOptions)
        end

        error("Unsupported TestAndPlayControl action: " .. tostring(action))
end

return handleTestAndPlayControl :: Types.ToolFunction
