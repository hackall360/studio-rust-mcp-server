local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")

export type ToolArgs = Types.ToolArgs
export type InstancePath = Types.InstancePath
export type DataModelSnapshotRequest = Types.DataModelSnapshotRequest
export type DataModelSnapshotResponse = Types.DataModelSnapshotResponse
export type DataModelSnapshotEntry = Types.DataModelSnapshotEntry
export type DataModelSnapshotPropertyPick = Types.DataModelSnapshotPropertyPick
export type DataModelSnapshotPropertyError = Types.DataModelSnapshotPropertyError

type PropertyPickConfig = {
        classes: { string },
        properties: { string },
        sampleCount: number?,
        randomize: boolean,
}

type TraversalItem = {
        instance: Instance,
        path: { string },
        depth: number,
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
        local normalised = normalisePath(path)
        local current: Instance = game

        for index, segment in normalised do
                local child = current:FindFirstChild(segment)
                if not child then
                        local parentName = if index == 1 then "game" else current:GetFullName()
                        return nil, normalised, string.format("Unable to find '%s' under %s", segment, parentName)
                end
                current = child
        end

        return current, normalised, nil
end

local function extendPath(path: { string }, segment: string): { string }
        local newPath = table.create(#path + 1)
        for index = 1, #path do
                newPath[index] = path[index]
        end
        newPath[#path + 1] = segment
        return newPath
end

local function cloneArray(list: { string }): { string }
        local copy = table.create(#list)
        for index = 1, #list do
                copy[index] = list[index]
        end
        return copy
end

local function shuffle(list: { string }, rng: Random)
        for index = #list, 2, -1 do
                local swapIndex = rng:NextInteger(1, index)
                list[index], list[swapIndex] = list[swapIndex], list[index]
        end
end

local function buildSet(list: { string }?): { [string]: boolean }?
        if type(list) ~= "table" then
                return nil
        end

        local set: { [string]: boolean } = {}
        for _, value in list do
                if type(value) == "string" and value ~= "" then
                        set[value] = true
                end
        end

        if next(set) == nil then
                return nil
        end

        return set
end

local function sanitisePropertyPicks(raw: { DataModelSnapshotPropertyPick }?): ({ PropertyPickConfig }, boolean)
        local picks: { PropertyPickConfig } = {}
        local needsRandom = false

        if type(raw) ~= "table" then
                return picks, needsRandom
        end

        for _, item in raw do
                if type(item) == "table" then
                        local properties = {}
                        if type(item.properties) == "table" then
                                for _, propertyName in item.properties do
                                        if type(propertyName) == "string" and propertyName ~= "" then
                                                table.insert(properties, propertyName)
                                        end
                                end
                        end

                        if #properties == 0 then
                                continue
                        end

                        local classes = {}
                        if type(item.classes) == "table" then
                                for _, className in item.classes do
                                        if type(className) == "string" and className ~= "" then
                                                table.insert(classes, className)
                                        end
                                end
                        end

                        local sampleCount: number? = nil
                        if type(item.sampleCount) == "number" then
                                local floored = math.floor(item.sampleCount)
                                if floored > 0 then
                                        sampleCount = floored
                                end
                        end

                        local randomize = item.randomize == true and sampleCount ~= nil
                        if randomize then
                                needsRandom = true
                        end

                        table.insert(picks, {
                                classes = classes,
                                properties = properties,
                                sampleCount = sampleCount,
                                randomize = randomize,
                        })
                end
        end

        return picks, needsRandom
end

local function gatherProperties(className: string, picks: { PropertyPickConfig }, rng: Random?): { string }
        if #picks == 0 then
                return {}
        end

        local result = {}
        local seen: { [string]: boolean } = {}

        for _, pick in picks do
                local applies = #pick.classes == 0
                if not applies then
                        for _, targetClass in pick.classes do
                                if targetClass == className then
                                        applies = true
                                        break
                                end
                        end
                end

                if applies then
                        local working = cloneArray(pick.properties)

                        if pick.sampleCount and pick.sampleCount > 0 and #working > pick.sampleCount then
                                if pick.randomize and rng then
                                        shuffle(working, rng)
                                end

                                local trimmed = table.create(pick.sampleCount)
                                for index = 1, pick.sampleCount do
                                        trimmed[index] = working[index]
                                end
                                working = trimmed
                        end

                        for _, propertyName in working do
                                if type(propertyName) == "string" and propertyName ~= "" and not seen[propertyName] then
                                        seen[propertyName] = true
                                        table.insert(result, propertyName)
                                end
                        end
                end
        end

        return result
end

local function encodeValue(value: any): any
        local valueType = typeof(value)

        if valueType == "nil" then
                return { type = "nil" }
        elseif valueType == "boolean" then
                return value
        elseif valueType == "number" then
                if value ~= value or value == math.huge or value == -math.huge then
                        return { type = "number", value = tostring(value) }
                end
                return value
        elseif valueType == "string" then
                return value
        elseif valueType == "Vector3" then
                local vector = value :: Vector3
                return { type = "Vector3", x = vector.X, y = vector.Y, z = vector.Z }
        elseif valueType == "Vector2" then
                local vector = value :: Vector2
                return { type = "Vector2", x = vector.X, y = vector.Y }
        elseif valueType == "Vector2int16" then
                local vector = value :: Vector2int16
                return { type = "Vector2int16", x = vector.X, y = vector.Y }
        elseif valueType == "Vector3int16" then
                local vector = value :: Vector3int16
                return { type = "Vector3int16", x = vector.X, y = vector.Y, z = vector.Z }
        elseif valueType == "CFrame" then
                local cf = value :: CFrame
                return { type = "CFrame", components = { cf:GetComponents() } }
        elseif valueType == "Color3" then
                local color = value :: Color3
                return { type = "Color3", r = color.R, g = color.G, b = color.B }
        elseif valueType == "BrickColor" then
                local brick = value :: BrickColor
                return { type = "BrickColor", name = brick.Name, number = brick.Number }
        elseif valueType == "UDim" then
                local udim = value :: UDim
                return { type = "UDim", scale = udim.Scale, offset = udim.Offset }
        elseif valueType == "UDim2" then
                local udim2 = value :: UDim2
                return {
                        type = "UDim2",
                        x = { scale = udim2.X.Scale, offset = udim2.X.Offset },
                        y = { scale = udim2.Y.Scale, offset = udim2.Y.Offset },
                }
        elseif valueType == "Rect" then
                local rect = value :: Rect
                return {
                        type = "Rect",
                        min = { x = rect.Min.X, y = rect.Min.Y },
                        max = { x = rect.Max.X, y = rect.Max.Y },
                }
        elseif valueType == "NumberRange" then
                local range = value :: NumberRange
                return { type = "NumberRange", min = range.Min, max = range.Max }
        elseif valueType == "PhysicalProperties" then
                local props = value :: PhysicalProperties
                return {
                        type = "PhysicalProperties",
                        density = props.Density,
                        friction = props.Friction,
                        elasticity = props.Elasticity,
                        frictionWeight = props.FrictionWeight,
                        elasticityWeight = props.ElasticityWeight,
                }
        elseif valueType == "EnumItem" then
                return { type = "EnumItem", value = tostring(value) }
        elseif valueType == "Instance" then
                local instance = value :: Instance
                local ok, fullName = pcall(instance.GetFullName, instance)
                return { type = "Instance", value = if ok then fullName else tostring(instance) }
        elseif valueType == "ColorSequence" then
                local sequence = value :: ColorSequence
                local keypoints = {}
                for index, keypoint in sequence.Keypoints do
                        keypoints[index] = {
                                time = keypoint.Time,
                                value = {
                                        r = keypoint.Value.R,
                                        g = keypoint.Value.G,
                                        b = keypoint.Value.B,
                                },
                        }
                end
                return { type = "ColorSequence", keypoints = keypoints }
        elseif valueType == "NumberSequence" then
                local sequence = value :: NumberSequence
                local keypoints = {}
                for index, keypoint in sequence.Keypoints do
                        keypoints[index] = {
                                time = keypoint.Time,
                                value = keypoint.Value,
                                envelope = keypoint.Envelope,
                        }
                end
                return { type = "NumberSequence", keypoints = keypoints }
        elseif valueType == "DateTime" then
                local dt = value :: DateTime
                return { type = "DateTime", value = dt:ToIsoDateTime() }
        end

        return { type = valueType, value = tostring(value) }
end

local function encodeAttributeMap(attributeMap: { [string]: any }): { [string]: any }
        local encoded: { [string]: any } = {}
        for key, value in attributeMap do
                if type(key) == "string" and key ~= "" then
                        encoded[key] = encodeValue(value)
                end
        end
        return encoded
end

local function createEntry(
        instance: Instance,
        path: { string },
        depth: number,
        childCount: number,
        includeAttributes: boolean,
        includeFullName: boolean,
        includeProperties: boolean,
        picks: { PropertyPickConfig },
        rng: Random?
): DataModelSnapshotEntry
        local entry: DataModelSnapshotEntry = {
                path = path,
                name = instance.Name,
                className = instance.ClassName,
                depth = depth,
                childCount = childCount,
        }

        if includeFullName then
                local okFullName, fullName = pcall(instance.GetFullName, instance)
                if okFullName then
                        entry.fullName = fullName
                else
                        entry.fullName = tostring(fullName)
                end
        end

        if includeAttributes then
                local okAttributes, attributes = pcall(instance.GetAttributes, instance)
                if okAttributes and type(attributes) == "table" then
                        entry.attributes = encodeAttributeMap(attributes)
                else
                        entry.attributeError = string.format("Failed to read attributes: %s", tostring(attributes))
                end
        end

        if includeProperties then
                local propertyNames = gatherProperties(instance.ClassName, picks, rng)
                if #propertyNames > 0 then
                        local properties: { [string]: any } = {}
                        local propertyErrors: { DataModelSnapshotPropertyError } = {}

                        for _, propertyName in propertyNames do
                                local okValue, value = pcall(function()
                                        return (instance :: any)[propertyName]
                                end)

                                if okValue then
                                        properties[propertyName] = encodeValue(value)
                                else
                                        table.insert(propertyErrors, {
                                                property = propertyName,
                                                message = tostring(value),
                                        })
                                end
                        end

                        entry.properties = properties
                        if #propertyErrors > 0 then
                                entry.propertyErrors = propertyErrors
                        end
                else
                        entry.properties = {}
                end
        end

        return entry
end

local function parsePositiveInteger(value: any): number?
        if type(value) == "number" then
                if value ~= value then
                        return nil
                end
                local floored = math.floor(value)
                if floored >= 1 then
                        return floored
                end
        end

        if type(value) == "string" then
                local parsed = tonumber(value)
                if parsed then
                        return parsePositiveInteger(parsed)
                end
        end

        return nil
end

local function handleDataModelSnapshot(args: ToolArgs): string?
        if args.tool ~= "DataModelSnapshot" then
                return nil
        end

        local params = args.params
        if type(params) ~= "table" then
                error("Missing params in DataModelSnapshot payload")
        end

        local request = (params :: any) :: DataModelSnapshotRequest

        local allowList = buildSet(request.classAllowList)
        local blockList = buildSet(request.classBlockList)

        local propertyPicks, needsRandom = sanitisePropertyPicks(request.propertyPicks)
        local includeProperties = if request.includeProperties == nil
                then #propertyPicks > 0
                else request.includeProperties == true
        local includeAttributes = request.includeAttributes ~= false
        local includeFullName = request.includeFullName ~= false
        local sortChildren = request.sortChildrenByName ~= false

        local maxDepth: number? = nil
        if type(request.maxDepth) == "number" then
                local floored = math.floor(request.maxDepth)
                if floored >= 0 then
                        maxDepth = floored
                end
        end

        local pageSize: number? = nil
        if type(request.pageSize) == "number" then
                local floored = math.floor(request.pageSize)
                if floored > 0 then
                        pageSize = floored
                end
        end

        local startIndex = 1
        if request.pageCursor ~= nil then
                local parsedCursor = parsePositiveInteger(request.pageCursor)
                if not parsedCursor then
                        error("pageCursor must be a positive integer or numeric string")
                end
                startIndex = parsedCursor
        end

        local rng: Random? = nil
        if needsRandom then
                local seed = request.randomSeed
                if type(seed) == "number" and seed == seed then
                        local floored = math.floor(seed)
                        local positive = if floored < 0 then -floored else floored
                        rng = Random.new(math.max(positive, 1))
                else
                        rng = Random.new()
                end
        end

        local roots = {}
        if type(request.rootPaths) == "table" and #request.rootPaths > 0 then
                for _, path in request.rootPaths do
                        local instance, normalised, err = resolveInstance(path)
                        if not instance then
                                error(err or "Unable to resolve root path")
                        end
                        table.insert(roots, {
                                instance = instance,
                                path = normalised,
                                depth = 0,
                        })
                end
        else
                table.insert(roots, {
                        instance = game,
                        path = {},
                        depth = 0,
                })
        end

        local stack: { TraversalItem } = {}
        for index = #roots, 1, -1 do
                table.insert(stack, roots[index])
        end

        local entries: { DataModelSnapshotEntry } = {}
        local totalVisited = 0
        local totalMatched = 0
        local truncated = false

        while #stack > 0 do
                local current = table.remove(stack)
                local instance = current.instance
                totalVisited += 1

                local className = instance.ClassName
                if blockList and blockList[className] then
                        continue
                end

                local children = instance:GetChildren()
                local childCount = #children

                local includeEntry = not allowList or allowList[className] == true
                if includeEntry then
                        totalMatched += 1
                        if totalMatched >= startIndex then
                                local entry = createEntry(
                                        instance,
                                        current.path,
                                        current.depth,
                                        childCount,
                                        includeAttributes,
                                        includeFullName,
                                        includeProperties,
                                        propertyPicks,
                                        rng
                                )
                                table.insert(entries, entry)

                                if pageSize and #entries >= pageSize then
                                        truncated = true
                                        break
                                end
                        end
                end

                local canTraverse = not maxDepth or current.depth < maxDepth
                if canTraverse and childCount > 0 then
                        if sortChildren then
                                table.sort(children, function(a, b)
                                        return string.lower(a.Name) < string.lower(b.Name)
                                end)
                        end

                        for childIndex = #children, 1, -1 do
                                local child = children[childIndex]
                                table.insert(stack, {
                                        instance = child,
                                        path = extendPath(current.path, child.Name),
                                        depth = current.depth + 1,
                                })
                        end
                end
        end

        local nextCursor: string? = nil
        if truncated then
                nextCursor = tostring(totalMatched + 1)
        end

        local response: DataModelSnapshotResponse = {
                entries = entries,
                nextCursor = nextCursor,
                totalMatched = totalMatched,
                totalVisited = totalVisited,
                truncated = truncated,
                metadata = {
                        generatedAt = DateTime.now():ToIsoDateTime(),
                        rootCount = #roots,
                        startIndex = startIndex,
                },
        }

        return HttpService:JSONEncode(response)
end

return handleDataModelSnapshot :: Types.ToolFunction
