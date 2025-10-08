local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")
local PathfindingService = game:GetService("PathfindingService")
local PhysicsService = game:GetService("PhysicsService")

type ToolArgs = Types.ToolArgs
type PhysicsAndNavigationResponse = Types.PhysicsAndNavigationResponse
type PhysicsAndNavigationOperationResult = Types.PhysicsAndNavigationOperationResult
type InstancePath = Types.InstancePath

type OperationSummary = {
    opResult: PhysicsAndNavigationOperationResult,
    writeOccurred: boolean,
    summary: string?,
}

local function normalisePath(path: InstancePath?): { string }
    local result = {}
    if type(path) ~= "table" then
        return result
    end

    for _, segment in path do
        if typeof(segment) == "string" and segment ~= "" and segment ~= "game" and segment ~= "DataModel" then
            table.insert(result, segment)
        end
    end

    return result
end

local function resolveInstance(path: InstancePath?): (Instance?, { string }, string?)
    local segments = normalisePath(path)
    if #segments == 0 then
        return game, segments, nil
    end

    local current: Instance = game
    for index, segment in segments do
        local child = current:FindFirstChild(segment)
        if not child then
            local parentName = if index == 1 then "game" else current:GetFullName()
            return nil, segments, string.format("Unable to find '%s' under %s", segment, parentName)
        end
        current = child
    end

    return current, segments, nil
end

local function vectorRecordFromVector3(vector: Vector3): Types.Vector3Record
    return {
        x = vector.X,
        y = vector.Y,
        z = vector.Z,
    }
end

local function parseVector3(record: any): (Vector3?, string?)
    if type(record) ~= "table" then
        return nil, "Vector3 record must be an object with x/y/z"
    end

    local x = record.x
    local y = record.y
    local z = record.z
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil, "Vector3 record requires numeric x, y, and z components"
    end

    return Vector3.new(x, y, z), nil
end

local function buildFailureResult(index: number, operationName: string, message: string, details: { [string]: any }?): OperationSummary
    return {
        opResult = {
            index = index,
            operation = operationName,
            success = false,
            message = message,
            details = details,
        },
        writeOccurred = false,
        summary = message,
    }
end

local function groupExists(groupName: string): (boolean?, string?)
    local ok, groups = pcall(PhysicsService.GetCollisionGroups, PhysicsService)
    if not ok then
        return nil, string.format("Unable to inspect collision groups: %s", tostring(groups))
    end

    if type(groups) == "table" then
        for _, info in groups do
            if type(info) == "table" and info.name == groupName then
                return true, nil
            end
        end
    end

    return false, nil
end

local function handleCreateCollisionGroup(index: number, operation: Types.PhysicsCreateCollisionGroupOperation): OperationSummary
    local groupName = operation.groupName
    if type(groupName) ~= "string" or groupName == "" then
        return buildFailureResult(index, "create_collision_group", "create_collision_group requires a non-empty groupName", nil)
    end

    local replaced = false
    if operation.replaceExisting == true then
        local exists = groupExists(groupName)
        if exists == true then
            pcall(PhysicsService.RemoveCollisionGroup, PhysicsService, groupName)
        end
        replaced = exists == true
    end

    local ok, err = pcall(PhysicsService.CreateCollisionGroup, PhysicsService, groupName)
    if not ok then
        local message = string.format("Failed to create collision group '%s': %s", groupName, tostring(err))
        return buildFailureResult(index, "create_collision_group", message, nil)
    end

    local details: { [string]: any } = { groupName = groupName }
    if replaced then
        details.replaced = true
    end

    local active = operation.active
    if type(active) == "boolean" then
        local okActive, activeErr = pcall(PhysicsService.CollisionGroupSetActive, PhysicsService, groupName, active)
        if okActive then
            details.active = active
        else
            details.activeError = tostring(activeErr)
        end
    end

    local message = if replaced
        then string.format("Collision group '%s' replaced", groupName)
        else string.format("Collision group '%s' created", groupName)

    return {
        opResult = {
            index = index,
            operation = "create_collision_group",
            success = true,
            message = message,
            details = details,
        },
        writeOccurred = true,
        summary = message,
    }
end

local function handleSetCollisionEnabled(index: number, operation: Types.PhysicsSetCollisionEnabledOperation): OperationSummary
    local groupA = operation.groupA
    local groupB = operation.groupB
    local collidable = operation.collidable

    if type(groupA) ~= "string" or groupA == "" then
        return buildFailureResult(index, "set_collision_enabled", "set_collision_enabled requires groupA", nil)
    end
    if type(groupB) ~= "string" or groupB == "" then
        return buildFailureResult(index, "set_collision_enabled", "set_collision_enabled requires groupB", nil)
    end
    if type(collidable) ~= "boolean" then
        return buildFailureResult(index, "set_collision_enabled", "set_collision_enabled requires a boolean collidable value", nil)
    end

    local existsA, errA = groupExists(groupA)
    if existsA == false then
        return buildFailureResult(index, "set_collision_enabled", string.format("Collision group '%s' was not found", groupA), nil)
    elseif existsA == nil then
        return buildFailureResult(index, "set_collision_enabled", errA or "Unable to inspect collision groups", nil)
    end

    local existsB, errB = groupExists(groupB)
    if existsB == false then
        return buildFailureResult(index, "set_collision_enabled", string.format("Collision group '%s' was not found", groupB), nil)
    elseif existsB == nil then
        return buildFailureResult(index, "set_collision_enabled", errB or "Unable to inspect collision groups", nil)
    end

    if type(operation.groupAActive) == "boolean" then
        pcall(PhysicsService.CollisionGroupSetActive, PhysicsService, groupA, operation.groupAActive)
    end
    if type(operation.groupBActive) == "boolean" then
        pcall(PhysicsService.CollisionGroupSetActive, PhysicsService, groupB, operation.groupBActive)
    end

    local ok, err = pcall(PhysicsService.CollisionGroupSetCollidable, PhysicsService, groupA, groupB, collidable)
    if not ok then
        local message = string.format("Failed to update collidability for '%s' and '%s': %s", groupA, groupB, tostring(err))
        return buildFailureResult(index, "set_collision_enabled", message, nil)
    end

    local message = string.format(
        "Collision between '%s' and '%s' set to %s",
        groupA,
        groupB,
        if collidable then "enabled" else "disabled"
    )

    local details: { [string]: any } = {
        groupA = groupA,
        groupB = groupB,
        collidable = collidable,
    }
    if type(operation.groupAActive) == "boolean" then
        details.groupAActive = operation.groupAActive
    end
    if type(operation.groupBActive) == "boolean" then
        details.groupBActive = operation.groupBActive
    end

    return {
        opResult = {
            index = index,
            operation = "set_collision_enabled",
            success = true,
            message = message,
            details = details,
        },
        writeOccurred = true,
        summary = message,
    }
end

local function handleAssignPartToGroup(index: number, operation: Types.PhysicsAssignPartToGroupOperation): OperationSummary
    local path = operation.path
    if type(path) ~= "table" or #path == 0 then
        return buildFailureResult(index, "assign_part_to_group", "assign_part_to_group requires a non-empty path", nil)
    end

    local groupName = operation.groupName
    if type(groupName) ~= "string" or groupName == "" then
        return buildFailureResult(index, "assign_part_to_group", "assign_part_to_group requires groupName", nil)
    end

    local exists, existsErr = groupExists(groupName)
    if exists == false then
        return buildFailureResult(index, "assign_part_to_group", string.format("Collision group '%s' was not found", groupName), nil)
    elseif exists == nil then
        return buildFailureResult(index, "assign_part_to_group", existsErr or "Unable to inspect collision groups", nil)
    end

    local instance, normalised, resolveErr = resolveInstance(path)
    if resolveErr then
        return buildFailureResult(
            index,
            "assign_part_to_group",
            string.format("Failed to resolve part path: %s", resolveErr),
            { path = normalised }
        )
    end

    if not instance or not instance:IsA("BasePart") then
        return buildFailureResult(
            index,
            "assign_part_to_group",
            "Resolved instance is not a BasePart",
            { path = normalised, className = instance and instance.ClassName or nil }
        )
    end

    local ok, err = pcall(PhysicsService.SetPartCollisionGroup, PhysicsService, instance, groupName)
    if not ok then
        return buildFailureResult(
            index,
            "assign_part_to_group",
            string.format("Failed to assign part to '%s': %s", groupName, tostring(err)),
            { path = normalised }
        )
    end

    local message = string.format("Assigned %s to collision group '%s'", instance:GetFullName(), groupName)

    return {
        opResult = {
            index = index,
            operation = "assign_part_to_group",
            success = true,
            message = message,
            details = {
                path = normalised,
                groupName = groupName,
            },
        },
        writeOccurred = true,
        summary = message,
    }
end

local function buildAgentParameters(agentParameters: Types.PhysicsAgentParameters?): ({ [string]: any }, { [string]: any }?)
    local params = {}
    local details = {}

    if type(agentParameters) ~= "table" then
        return params, nil
    end

    if type(agentParameters.agentRadius) == "number" then
        params.AgentRadius = agentParameters.agentRadius
        details.agentRadius = agentParameters.agentRadius
    end
    if type(agentParameters.agentHeight) == "number" then
        params.AgentHeight = agentParameters.agentHeight
        details.agentHeight = agentParameters.agentHeight
    end
    if type(agentParameters.agentCanJump) == "boolean" then
        params.AgentCanJump = agentParameters.agentCanJump
        details.agentCanJump = agentParameters.agentCanJump
    end
    if type(agentParameters.agentMaxSlope) == "number" then
        params.AgentMaxSlope = agentParameters.agentMaxSlope
        details.agentMaxSlope = agentParameters.agentMaxSlope
    end

    return params, if next(details) ~= nil then details else nil
end

local function handleComputePath(index: number, operation: Types.PhysicsComputePathOperation): OperationSummary
    local startPosition, startErr = parseVector3(operation.startPosition)
    if not startPosition then
        return buildFailureResult(index, "compute_path", string.format("Invalid startPosition: %s", startErr), nil)
    end

    local targetPosition, targetErr = parseVector3(operation.targetPosition)
    if not targetPosition then
        return buildFailureResult(index, "compute_path", string.format("Invalid targetPosition: %s", targetErr), nil)
    end

    local createParams, agentDetails = buildAgentParameters(operation.agentParameters)

    local okCreate, pathOrError = pcall(PathfindingService.CreatePath, PathfindingService, createParams)
    if not okCreate then
        return buildFailureResult(index, "compute_path", string.format("Failed to create path: %s", tostring(pathOrError)), nil)
    end

    local path = pathOrError :: Path
    local okCompute, computeErr = pcall(path.ComputeAsync, path, startPosition, targetPosition)
    if not okCompute then
        return buildFailureResult(index, "compute_path", string.format("Failed to compute path: %s", tostring(computeErr)), nil)
    end

    local status = path.Status
    local statusName = status.Name

    local waypoints = {}
    local rawWaypoints = path:GetWaypoints()
    for _, waypoint in rawWaypoints do
        local positionRecord = vectorRecordFromVector3(waypoint.Position)
        local entry: Types.PhysicsWaypoint = {
            position = positionRecord,
            action = waypoint.Action.Name,
            label = waypoint.Label,
        }
        if waypoint.Label == nil then
            entry.label = nil
        end
        table.insert(waypoints, entry)
    end

    local success = status == Enum.PathStatus.Success
    local blocked = status == Enum.PathStatus.ClosestNoPath or status == Enum.PathStatus.NoPath

    local message = if success
        then string.format("Computed path with %d waypoints", #waypoints)
        else string.format("Path computation returned status %s", statusName)

    local details: { [string]: any } = {
        status = statusName,
        blocked = blocked,
        waypoints = waypoints,
        startPosition = vectorRecordFromVector3(startPosition),
        targetPosition = vectorRecordFromVector3(targetPosition),
    }
    if agentDetails then
        details.agentParameters = agentDetails
    end

    if not success then
        details.message = message
    end

    return {
        opResult = {
            index = index,
            operation = "compute_path",
            success = success,
            message = message,
            details = details,
        },
        writeOccurred = false,
        summary = message,
    }
end

local operationHandlers = {
    create_collision_group = handleCreateCollisionGroup,
    set_collision_enabled = handleSetCollisionEnabled,
    assign_part_to_group = handleAssignPartToGroup,
    compute_path = handleComputePath,
}

local function handlePhysicsAndNavigation(args: ToolArgs): string?
    if args.tool ~= "PhysicsAndNavigation" then
        return nil
    end

    local params = args.params
    if type(params) ~= "table" then
        error("Missing params in PhysicsAndNavigation payload")
    end

    local operations = params.operations
    if type(operations) ~= "table" then
        error("PhysicsAndNavigation requires an operations array")
    end

    local results: { PhysicsAndNavigationOperationResult } = {}
    local summaryParts = {}
    local writeOccurred = false

    for index, operation in operations do
        if type(operation) ~= "table" then
            local message = string.format("Operation at index %d must be an object", index)
            table.insert(results, {
                index = index,
                operation = "unknown",
                success = false,
                message = message,
                details = nil,
            })
            table.insert(summaryParts, message)
            continue
        end

        local operationName = operation.operation
        if type(operationName) ~= "string" then
            local message = string.format("Operation at index %d is missing an 'operation' field", index)
            table.insert(results, {
                index = index,
                operation = "unknown",
                success = false,
                message = message,
                details = nil,
            })
            table.insert(summaryParts, message)
            continue
        end

        local handler = operationHandlers[operationName]
        if not handler then
            local message = string.format("Unsupported PhysicsAndNavigation operation '%s'", tostring(operationName))
            table.insert(results, {
                index = index,
                operation = operationName,
                success = false,
                message = message,
                details = nil,
            })
            table.insert(summaryParts, message)
            continue
        end

        local summary = handler(index, operation)
        table.insert(results, summary.opResult)
        if summary.summary then
            table.insert(summaryParts, summary.summary)
        end
        if summary.writeOccurred then
            writeOccurred = true
        end
    end

    local response: PhysicsAndNavigationResponse = {
        results = results,
        summary = if #summaryParts > 0 then table.concat(summaryParts, "; ") else nil,
        writeOccurred = writeOccurred,
    }

    return HttpService:JSONEncode(response)
end

return handlePhysicsAndNavigation :: Types.ToolFunction
