local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

type InstancePath = Types.InstancePath
type CollectionAndAttributesOperationResult = Types.CollectionAndAttributesOperationResult
type CollectionAndAttributesRequest = Types.CollectionAndAttributesRequest
type CollectionAndAttributesResponse = Types.CollectionAndAttributesResponse

type OperationHandlerResult = {
        opResult: CollectionAndAttributesOperationResult,
        writeOccurred: boolean,
        affectedInstances: number,
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

local function getInstancePathSegments(instance: Instance?): { string }
        local segments = {}
        local current = instance
        while current and current ~= game do
                table.insert(segments, 1, current.Name)
                current = current.Parent
        end
        return segments
end

local function resolveInstance(path: InstancePath?): (Instance?, { string }, string?)
        local normalised = normalisePath(path)
        if #normalised == 0 then
                return game, normalised, nil
        end

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

local function buildFailureResult(index: number, operationName: string, message: string): OperationHandlerResult
        return {
                opResult = {
                        index = index,
                        operation = operationName,
                        success = false,
                        message = message,
                },
                writeOccurred = false,
                affectedInstances = 0,
                summary = message,
        }
end

local function handleListTags(index: number, operation: Types.CollectionListTagsOperation): OperationHandlerResult
        local paths = operation.paths
        if type(paths) ~= "table" or #paths == 0 then
                return buildFailureResult(index, "list_tags", "list_tags requires at least one instance path")
        end

        local includeAttributes = operation.includeAttributes == true
        local details = { instances = {} }
        local successes = 0

        for _, path in paths do
                local instance, normalised, err = resolveInstance(path)
                local entry = {
                        path = normalised,
                }

                if err then
                        entry.success = false
                        entry.error = err
                else
                        local okTags, tags = pcall(CollectionService.GetTags, CollectionService, instance)
                        if okTags and type(tags) == "table" then
                                entry.tags = tags
                        else
                                entry.error = string.format("Failed to read tags: %s", tostring(tags))
                        end

                        if includeAttributes then
                                local okAttributes, attributes = pcall(instance.GetAttributes, instance)
                                if okAttributes and type(attributes) == "table" then
                                        entry.attributes = attributes
                                else
                                        entry.attributeError = string.format("Failed to read attributes: %s", tostring(attributes))
                                end
                        end

                        if entry.error == nil and entry.attributeError == nil then
                                entry.success = true
                                successes += 1
                        else
                                entry.success = false
                        end
                end

                table.insert(details.instances, entry)
        end

        local total = #details.instances
        local message = string.format("Collected tags for %d/%d instances", successes, total)

        return {
                opResult = {
                        index = index,
                        operation = "list_tags",
                        success = successes == total and total > 0,
                        message = message,
                        details = details,
                },
                writeOccurred = false,
                affectedInstances = 0,
                summary = message,
        }
end

local function handleAddTags(index: number, operation: Types.CollectionAddTagsOperation): OperationHandlerResult
        local paths = operation.paths
        local tags = operation.tags
        if type(paths) ~= "table" or #paths == 0 then
                return buildFailureResult(index, "add_tags", "add_tags requires at least one instance path")
        end
        if type(tags) ~= "table" or #tags == 0 then
                return buildFailureResult(index, "add_tags", "add_tags requires at least one tag")
        end

        local details = { instances = {} }
        local modifiedInstances = 0
        local totalAssignments = 0
        local successes = 0

        for _, path in paths do
                local instance, normalised, err = resolveInstance(path)
                local entry = {
                        path = normalised,
                }

                if err then
                        entry.success = false
                        entry.error = err
                else
                        local added = {}
                        local skipped = {}
                        local errors = {}

                        for _, tag in tags do
                                if typeof(tag) ~= "string" or tag == "" then
                                        table.insert(errors, string.format("Invalid tag '%s'", tostring(tag)))
                                elseif CollectionService:HasTag(instance, tag) then
                                        table.insert(skipped, tag)
                                else
                                        local ok, errMessage = pcall(CollectionService.AddTag, CollectionService, instance, tag)
                                        if ok then
                                                table.insert(added, tag)
                                        else
                                                table.insert(errors, string.format("Failed to add '%s': %s", tag, tostring(errMessage)))
                                        end
                                end
                        end

                        if #added > 0 then
                                entry.added = added
                                totalAssignments += #added
                                modifiedInstances += 1
                        end
                        if #skipped > 0 then
                                entry.skipped = skipped
                        end
                        if #errors > 0 then
                                entry.errors = errors
                                entry.success = false
                        else
                                entry.success = true
                                successes += 1
                        end
                end

                table.insert(details.instances, entry)
        end

        local total = #details.instances
        local message = string.format(
                "Added tags to %d/%d instances (%d new assignments)",
                modifiedInstances,
                total,
                totalAssignments
        )

        return {
                opResult = {
                        index = index,
                        operation = "add_tags",
                        success = successes == total and total > 0,
                        message = message,
                        details = details,
                },
                writeOccurred = modifiedInstances > 0,
                affectedInstances = modifiedInstances,
                summary = message,
        }
end

local function handleRemoveTags(index: number, operation: Types.CollectionRemoveTagsOperation): OperationHandlerResult
        local paths = operation.paths
        local tags = operation.tags
        if type(paths) ~= "table" or #paths == 0 then
                return buildFailureResult(index, "remove_tags", "remove_tags requires at least one instance path")
        end
        if type(tags) ~= "table" or #tags == 0 then
                return buildFailureResult(index, "remove_tags", "remove_tags requires at least one tag")
        end

        local details = { instances = {} }
        local modifiedInstances = 0
        local totalRemovals = 0
        local successes = 0

        for _, path in paths do
                local instance, normalised, err = resolveInstance(path)
                local entry = {
                        path = normalised,
                }

                if err then
                        entry.success = false
                        entry.error = err
                else
                        local removed = {}
                        local skipped = {}
                        local errors = {}

                        for _, tag in tags do
                                if typeof(tag) ~= "string" or tag == "" then
                                        table.insert(errors, string.format("Invalid tag '%s'", tostring(tag)))
                                elseif CollectionService:HasTag(instance, tag) then
                                        local ok, errMessage = pcall(CollectionService.RemoveTag, CollectionService, instance, tag)
                                        if ok then
                                                table.insert(removed, tag)
                                        else
                                                table.insert(errors, string.format("Failed to remove '%s': %s", tag, tostring(errMessage)))
                                        end
                                else
                                        table.insert(skipped, tag)
                                end
                        end

                        if #removed > 0 then
                                entry.removed = removed
                                totalRemovals += #removed
                                modifiedInstances += 1
                        end
                        if #skipped > 0 then
                                entry.skipped = skipped
                        end
                        if #errors > 0 then
                                entry.errors = errors
                                entry.success = false
                        else
                                entry.success = true
                                successes += 1
                        end
                end

                table.insert(details.instances, entry)
        end

        local total = #details.instances
        local message = string.format(
                "Removed tags from %d/%d instances (%d removals)",
                modifiedInstances,
                total,
                totalRemovals
        )

        return {
                opResult = {
                        index = index,
                        operation = "remove_tags",
                        success = successes == total and total > 0,
                        message = message,
                        details = details,
                },
                writeOccurred = modifiedInstances > 0,
                affectedInstances = modifiedInstances,
                summary = message,
        }
end

local function handleSyncAttributes(index: number, operation: Types.CollectionSyncAttributesOperation): OperationHandlerResult
        local paths = operation.paths
        local attributes = operation.attributes
        if type(paths) ~= "table" or #paths == 0 then
                return buildFailureResult(index, "sync_attributes", "sync_attributes requires at least one instance path")
        end
        if type(attributes) ~= "table" then
                return buildFailureResult(index, "sync_attributes", "sync_attributes requires an attributes object")
        end

        local clearMissing = operation.clearMissing == true
        local details = { instances = {} }
        local modifiedInstances = 0
        local successes = 0

        for _, path in paths do
                local instance, normalised, err = resolveInstance(path)
                local entry = {
                        path = normalised,
                }

                if err then
                        entry.success = false
                        entry.error = err
                else
                        local errors = {}
                        local updated = {}
                        local removed = {}

                        local okExisting, existingAttributes = pcall(instance.GetAttributes, instance)
                        if not okExisting then
                                local errMessage = tostring(existingAttributes)
                                existingAttributes = {}
                                table.insert(errors, string.format("Failed to read current attributes: %s", errMessage))
                        end

                        for key, value in attributes do
                                if typeof(key) ~= "string" or key == "" then
                                        table.insert(errors, string.format("Invalid attribute key '%s'", tostring(key)))
                                else
                                        local okWrite, errWrite = pcall(instance.SetAttribute, instance, key, value)
                                        if okWrite then
                                                table.insert(updated, key)
                                        else
                                                table.insert(errors, string.format("Failed to set '%s': %s", key, tostring(errWrite)))
                                        end
                                end
                        end

                        if clearMissing and type(existingAttributes) == "table" then
                                for key, _ in existingAttributes do
                                        if attributes[key] == nil then
                                                local okRemove, errRemove = pcall(instance.SetAttribute, instance, key, nil)
                                                if okRemove then
                                                        table.insert(removed, key)
                                                else
                                                        table.insert(errors, string.format("Failed to clear '%s': %s", key, tostring(errRemove)))
                                                end
                                        end
                                end
                        end

                        if #updated > 0 then
                                entry.updated = updated
                        end
                        if #removed > 0 then
                                entry.removed = removed
                        end
                        if #errors > 0 then
                                entry.errors = errors
                                entry.success = false
                        else
                                entry.success = true
                                successes += 1
                        end
                        if #updated > 0 or #removed > 0 then
                                modifiedInstances += 1
                        end

                        local okAttributes, finalAttributes = pcall(instance.GetAttributes, instance)
                        if okAttributes and type(finalAttributes) == "table" then
                                entry.attributes = finalAttributes
                        end
                end

                table.insert(details.instances, entry)
        end

        local total = #details.instances
        local message = string.format("Synchronized attributes for %d/%d instances", successes, total)

        return {
                opResult = {
                        index = index,
                        operation = "sync_attributes",
                        success = successes == total and total > 0,
                        message = message,
                        details = details,
                },
                writeOccurred = modifiedInstances > 0,
                affectedInstances = modifiedInstances,
                summary = message,
        }
end

local function handleQueryByTag(index: number, operation: Types.CollectionQueryByTagOperation): OperationHandlerResult
        local tag = operation.tag
        if typeof(tag) ~= "string" or tag == "" then
                return buildFailureResult(index, "query_by_tag", "query_by_tag requires a non-empty tag string")
        end

        local includeAttributes = operation.includeAttributes == true
        local includePaths = operation.includePaths ~= false
        local ok, taggedInstances = pcall(CollectionService.GetTagged, CollectionService, tag)
        if not ok or type(taggedInstances) ~= "table" then
                local message = string.format("Failed to query tag '%s': %s", tag, tostring(taggedInstances))
                return buildFailureResult(index, "query_by_tag", message)
        end

        local details = {
                tag = tag,
                count = #taggedInstances,
                instances = table.create(#taggedInstances),
        }

        for _, instance in taggedInstances do
                local entry = {
                        name = instance.Name,
                        className = instance.ClassName,
                }

                if includePaths then
                        entry.path = getInstancePathSegments(instance)
                end

                local okTags, tags = pcall(CollectionService.GetTags, CollectionService, instance)
                if okTags and type(tags) == "table" then
                        entry.tags = tags
                end

                if includeAttributes then
                        local okAttributes, attributes = pcall(instance.GetAttributes, instance)
                        if okAttributes and type(attributes) == "table" then
                                entry.attributes = attributes
                        end
                end

                table.insert(details.instances, entry)
        end

        local message = string.format("Found %d instances tagged '%s'", #taggedInstances, tag)

        return {
                opResult = {
                        index = index,
                        operation = "query_by_tag",
                        success = true,
                        message = message,
                        details = details,
                },
                writeOccurred = false,
                affectedInstances = 0,
                summary = message,
        }
end

local OPERATION_HANDLERS: { [string]: (number, CollectionAndAttributesOperation) -> OperationHandlerResult } = {
        list_tags = function(index, operation)
                return handleListTags(index, operation :: Types.CollectionListTagsOperation)
        end,
        add_tags = function(index, operation)
                return handleAddTags(index, operation :: Types.CollectionAddTagsOperation)
        end,
        remove_tags = function(index, operation)
                return handleRemoveTags(index, operation :: Types.CollectionRemoveTagsOperation)
        end,
        sync_attributes = function(index, operation)
                return handleSyncAttributes(index, operation :: Types.CollectionSyncAttributesOperation)
        end,
        query_by_tag = function(index, operation)
                return handleQueryByTag(index, operation :: Types.CollectionQueryByTagOperation)
        end,
}

local function handleCollectionAndAttributes(args: Types.ToolArgs): string?
        if args.tool ~= "CollectionAndAttributes" then
                return nil
        end

        local params = args.params :: CollectionAndAttributesRequest
        if type(params) ~= "table" then
                error("Missing params in CollectionAndAttributes payload")
        end

        local operations = params.operations
        if type(operations) ~= "table" or #operations == 0 then
                error("CollectionAndAttributes requires at least one operation")
        end

        local results = table.create(#operations)
        local summaries = {}
        local totalAffected = 0
        local writeOccurred = false

        for index, operation in operations do
                local operationName = if type(operation) == "table" then operation.operation else nil
                local handler = if type(operationName) == "string" then OPERATION_HANDLERS[operationName] else nil
                if not handler then
                        local message = string.format("Unsupported operation '%s'", tostring(operationName))
                        results[index] = {
                                index = index,
                                operation = tostring(operationName or "unknown"),
                                success = false,
                                message = message,
                        }
                        table.insert(summaries, message)
                else
                        local outcome = handler(index, operation)
                        results[index] = outcome.opResult
                        if outcome.summary and outcome.summary ~= "" then
                                table.insert(summaries, outcome.summary)
                        elseif outcome.opResult.message and outcome.opResult.message ~= "" then
                                table.insert(summaries, outcome.opResult.message)
                        end
                        if outcome.writeOccurred then
                                writeOccurred = true
                        end
                        totalAffected += outcome.affectedInstances
                end
        end

        local response: CollectionAndAttributesResponse = {
                results = results,
                summary = if #summaries > 0 then table.concat(summaries, " | ") else nil,
                writeOccurred = writeOccurred,
                affectedInstances = if totalAffected > 0 then totalAffected else nil,
        }

        return HttpService:JSONEncode(response)
end

return handleCollectionAndAttributes :: Types.ToolFunction
