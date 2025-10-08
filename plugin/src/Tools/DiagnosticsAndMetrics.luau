local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local StatsService = game:GetService("Stats")

local DEFAULT_SERVICES = {
        "Workspace",
        "Players",
        "Lighting",
        "ReplicatedStorage",
        "ServerScriptService",
}

local MEMORY_TAG_OVERRIDES: { [string]: string } = {
        ServerScriptService = "Script",
        StarterGui = "Gui",
        StarterPlayer = "StarterPlayer",
        StarterPack = "StarterPack",
}

local MICROPROFILER_CHUNK_SIZE = 200000

local function chunkText(text: string, chunkSize: number)
        local chunks = {}
        local length = #text
        local index = 1
        local chunkIndex = 1
        while index <= length do
                local upper = math.min(index + chunkSize - 1, length)
                table.insert(chunks, {
                        index = chunkIndex,
                        startByte = index,
                        endByte = upper,
                        data = string.sub(text, index, upper),
                })
                index = upper + 1
                chunkIndex += 1
        end
        return chunks
end

local function boolDefault(value: any, fallback: boolean): boolean
        if type(value) == "boolean" then
                return value
        end
        return fallback
end

local function numberDefault(value: any, fallback: number, minValue: number?): number
        if type(value) == "number" and value == value then
                if minValue and value < minValue then
                        return fallback
                end
                return value
        end
        return fallback
end

local function findEnumByName(enumType: Enum, name: string)
        for _, item in enumType:GetEnumItems() do
                if item.Name == name then
                        return item
                end
        end
        return nil
end

local function isoTimestampFromEntry(entry: { [string]: any }): string?
        local candidate = entry.timestamp or entry.time or entry.Time
        if typeof(candidate) == "DateTime" then
                return candidate:ToIsoDateTime()
        elseif type(candidate) == "number" then
                local ok, value = pcall(DateTime.fromUnixTimestamp, candidate)
                if ok and typeof(value) == "DateTime" then
                        return value:ToIsoDateTime()
                end
        elseif type(candidate) == "string" then
                return candidate
        end
        return nil
end

local function severityFromMessageType(messageType: Enum.MessageType?): string
        if messageType == Enum.MessageType.MessageError then
                return "error"
        elseif messageType == Enum.MessageType.MessageWarning then
                return "warning"
        elseif messageType == Enum.MessageType.MessageInfo then
                return "info"
        elseif messageType == Enum.MessageType.MessageOutput then
                return "info"
        end
        return "info"
end

local function gatherLogHistory(options: Types.DiagnosticsLogOptions?): { [string]: any }?
        local resolved: Types.DiagnosticsLogOptions = (options or {}) :: Types.DiagnosticsLogOptions

        local includeErrors = boolDefault(resolved.includeErrors, true)
        local includeWarnings = boolDefault(resolved.includeWarnings, true)
        local includeInfo = boolDefault(resolved.includeInfo, false)

        local maxEntries = resolved.maxEntries
        if type(maxEntries) ~= "number" or maxEntries <= 0 then
                maxEntries = nil
        end

        local chunkSize = numberDefault(resolved.chunkSize, 100, 1)
        chunkSize = math.max(math.floor(chunkSize), 1)

        local ok, history = pcall(LogService.GetLogHistory, LogService)
        if not ok or type(history) ~= "table" then
                return {
                        available = false,
                        reason = if ok
                                then "LogService returned unexpected data"
                                else tostring(history),
                }
        end

        local filtered = {}
        for _, entry in history do
                if type(entry) == "table" then
                        local severity = severityFromMessageType(entry.messageType)
                        local shouldInclude = if severity == "error"
                                then includeErrors
                                elseif severity == "warning"
                                then includeWarnings
                                else includeInfo
                        if shouldInclude then
                                table.insert(filtered, {
                                        message = tostring(entry.message),
                                        severity = severity,
                                        timestamp = isoTimestampFromEntry(entry),
                                        source = entry.source,
                                })
                        end
                end
        end

        local truncated = false
        if maxEntries and #filtered > maxEntries then
                truncated = true
                local startIndex = math.max(#filtered - maxEntries + 1, 1)
                local trimmed = {}
                for index = startIndex, #filtered do
                        table.insert(trimmed, filtered[index])
                end
                filtered = trimmed
        end

        local severityCounts = {
                error = 0,
                warning = 0,
                info = 0,
        }
        local oldestTimestamp: string? = nil
        local newestTimestamp: string? = nil
        for _, entry in filtered do
                local severity = entry.severity
                severityCounts[severity] = (severityCounts[severity] or 0) + 1
                local timestamp = entry.timestamp
                if timestamp ~= nil then
                        if oldestTimestamp == nil then
                                oldestTimestamp = timestamp
                        end
                        newestTimestamp = timestamp
                end
        end

        local chunks = {}
        local index = 1
        local chunkIndex = 1
        while index <= #filtered do
                local chunkStart = index
                local chunk = {}
                local upper = math.min(index + chunkSize - 1, #filtered)
                for i = index, upper do
                        table.insert(chunk, filtered[i])
                end
                table.insert(chunks, {
                        index = chunkIndex,
                        startEntry = chunkStart,
                        endEntry = upper,
                        entries = chunk,
                })
                index = upper + 1
                chunkIndex += 1
        end

        return {
                available = true,
                totalEntries = #filtered,
                totalChunks = #chunks,
                chunkSize = chunkSize,
                truncated = truncated,
                severityCounts = severityCounts,
                oldestTimestamp = oldestTimestamp,
                newestTimestamp = newestTimestamp,
                chunks = chunks,
        }
end

local function gatherMemoryStats(includeMemory: boolean?): { [string]: any }?
        if not boolDefault(includeMemory, true) then
                return nil
        end

        local data: { [string]: any } = {
                available = true,
        }

        local okTotal, totalMemory = pcall(StatsService.GetTotalMemoryUsageMb, StatsService)
        if okTotal then
                data.totalMemoryMb = totalMemory
        end

        local tagNames = {
                "Workspace",
                "Instances",
                "PhysicsParts",
                "Script",
                "Gui",
                "Terrain",
                "Navigation",
                "Particles",
                "Animation",
                "Sounds",
                "Network",
                "LuaHeap",
        }

        local tagBreakdown = {}
        for _, name in tagNames do
                local tag = findEnumByName(Enum.DeveloperMemoryTag, name)
                if tag then
                        local okValue, value = pcall(StatsService.GetMemoryUsageMbForTag, StatsService, tag)
                        if okValue then
                                tagBreakdown[name] = value
                        end
                end
        end
        if next(tagBreakdown) ~= nil then
                data.tags = tagBreakdown
        end

        return data
end

local function findMemoryTagForService(serviceName: string)
        local candidates = { serviceName }
        local override = MEMORY_TAG_OVERRIDES[serviceName]
        if override then
                table.insert(candidates, override)
        end
        for _, candidate in candidates do
                local tag = findEnumByName(Enum.DeveloperMemoryTag, candidate)
                if tag then
                        return tag
                end
        end
        return nil
end

local function gatherServiceMetrics(selection: Types.DiagnosticsServiceSelection?): { [string]: any }?
        local resolved: Types.DiagnosticsServiceSelection = (selection or {}) :: Types.DiagnosticsServiceSelection
        local services = resolved.services
        if type(services) ~= "table" or #services == 0 then
                services = DEFAULT_SERVICES
        end

        local includeCounts = boolDefault(resolved.includeDescendantCounts, true)
        local includeMemoryTags = boolDefault(resolved.includeMemoryTags, true)

        local results: { [string]: any } = {}
        for _, serviceName in services do
                if type(serviceName) == "string" then
                        local entry = {
                                name = serviceName,
                        }

                        local success, serviceOrError = pcall(game.GetService, game, serviceName)
                        if success and serviceOrError then
                                entry.available = true
                                if includeCounts then
                                        local okCount, descendantCount = pcall(function()
                                                return #serviceOrError:GetDescendants()
                                        end)
                                        if okCount then
                                                entry.descendantCount = descendantCount
                                        end
                                end

                                if includeMemoryTags then
                                        local tag = findMemoryTagForService(serviceName)
                                        if tag then
                                                local okUsage, usage = pcall(StatsService.GetMemoryUsageMbForTag, StatsService, tag)
                                                if okUsage then
                                                        entry.memoryUsageMb = usage
                                                end
                                        end
                                end
                        else
                                entry.available = false
                                entry.reason = tostring(serviceOrError)
                        end

                        results[serviceName] = entry
                end
        end

        return {
                includeDescendantCounts = includeCounts,
                includeMemoryTags = includeMemoryTags,
                services = results,
        }
end

local function gatherMicroProfiler(includeMicroProfiler: boolean?): { [string]: any }?
        if not boolDefault(includeMicroProfiler, false) then
                return nil
        end

        local okDump, dump = pcall(LogService.GetMicroProfilerDump, LogService)
        if not okDump then
                return {
                        available = false,
                        reason = tostring(dump),
                }
        end

        if type(dump) == "string" then
                local snapshotSize = #dump
                if snapshotSize <= MICROPROFILER_CHUNK_SIZE then
                        return {
                                available = true,
                                snapshot = dump,
                                snapshotSize = snapshotSize,
                        }
                end
                local chunks = chunkText(dump, MICROPROFILER_CHUNK_SIZE)
                return {
                        available = true,
                        snapshotSize = snapshotSize,
                        chunkSize = MICROPROFILER_CHUNK_SIZE,
                        chunks = chunks,
                }
        end

        return {
                available = false,
                reason = "Microprofiler dump unavailable or unsupported",
        }
end

local function gatherTaskScheduler(includeScheduler: boolean?): { [string]: any }?
        if not boolDefault(includeScheduler, true) then
                return nil
        end

        local success, scheduler = pcall(game.GetService, game, "TaskScheduler")
        if not success or not scheduler then
                return {
                        available = false,
                        reason = tostring(scheduler),
                }
        end

        local data: { [string]: any } = {
                available = true,
        }

        local okState, state = pcall(function()
                if scheduler.GetState then
                        return scheduler:GetState()
                elseif scheduler.GetSchedulerState then
                        return scheduler:GetSchedulerState()
                end
                return nil
        end)
        if okState and state ~= nil then
                data.state = state
        end

        local okStats, stats = pcall(function()
                if scheduler.GetSchedulerStats then
                        return scheduler:GetSchedulerStats()
                elseif scheduler.GetThreadStats then
                        return scheduler:GetThreadStats()
                end
                return nil
        end)
        if okStats and type(stats) == "table" then
                data.stats = stats
        end

        if data.state == nil and data.stats == nil then
                data.available = false
                data.reason = "TaskScheduler metrics not exposed in this environment"
        end

        return data
end

local function handleDiagnosticsAndMetrics(args: Types.ToolArgs): string?
        if args.tool ~= "DiagnosticsAndMetrics" then
                return nil
        end

        local params = args.params :: Types.DiagnosticsAndMetricsArgs
        if type(params) ~= "table" then
                error("Missing params in DiagnosticsAndMetrics payload")
        end

        if params.logs ~= nil and type(params.logs) ~= "table" then
                error("Invalid logs configuration in DiagnosticsAndMetrics params")
        end
        if params.serviceSelection ~= nil and type(params.serviceSelection) ~= "table" then
                error("Invalid serviceSelection in DiagnosticsAndMetrics params")
        end

        local logSection = gatherLogHistory(params.logs)
        local memorySection = gatherMemoryStats(params.includeMemoryStats)
        local microProfilerSection = gatherMicroProfiler(params.includeMicroProfiler)
        local servicesSection = gatherServiceMetrics(params.serviceSelection)
        local schedulerSection = gatherTaskScheduler(params.includeTaskScheduler)

        local payload: { [string]: any } = {
                metadata = {
                        generatedAt = DateTime.now():ToIsoDateTime(),
                },
        }

        if logSection then
                payload.logs = logSection
        end
        if memorySection then
                payload.memory = memorySection
        end
        if microProfilerSection then
                payload.microProfiler = microProfilerSection
        end
        if servicesSection then
                payload.services = servicesSection
        end
        if schedulerSection then
                payload.taskScheduler = schedulerSection
        end

        return HttpService:JSONEncode(payload)
end

return handleDiagnosticsAndMetrics :: Types.ToolFunction
