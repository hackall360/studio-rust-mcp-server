local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")
local SelectionService = game:GetService("Selection")
local Workspace = game:GetService("Workspace")

local DEFAULT_SERVICES = {
	"Workspace",
	"Players",
	"Lighting",
	"ReplicatedStorage",
	"ServerScriptService",
	"StarterGui",
}

local function boolDefault(value: any, fallback: boolean): boolean
	if type(value) == "boolean" then
		return value
	end
	return fallback
end

local function vectorToTable(vector: Vector3): Types.Vector3Record
        return {
                x = vector.X,
                y = vector.Y,
                z = vector.Z,
        }
end

local function cframeToTable(cf: CFrame): Types.InspectCameraFrame
        return {
                position = vectorToTable(cf.Position),
                lookVector = vectorToTable(cf.LookVector),
                upVector = vectorToTable(cf.UpVector),
                rightVector = vectorToTable(cf.RightVector),
        }
end

local function gatherSelection(scope: Types.InspectSelectionScope?): Types.InspectSelectionResult
        local resolvedScope: Types.InspectSelectionScope = (scope or {}) :: Types.InspectSelectionScope

        local includeNames = boolDefault(resolvedScope.includeNames, true)
        local includeClassNames = boolDefault(resolvedScope.includeClassNames, true)
        local includeFullNames = boolDefault(resolvedScope.includeFullNames, true)

        local items: { Types.InspectSelectionItem } = {}
        for _, instance in SelectionService:Get() do
                local entry: Types.InspectSelectionItem = {}
                if includeNames then
                        entry.name = instance.Name
                end
		if includeClassNames then
			entry.className = instance.ClassName
		end
		if includeFullNames then
			entry.fullName = instance:GetFullName()
		end

		table.insert(items, entry)
	end

        return {
                total = #items,
                items = items,
        }
end

local function gatherCamera(scope: Types.InspectCameraScope?): Types.InspectCameraResult
        local resolvedScope: Types.InspectCameraScope = (scope or {}) :: Types.InspectCameraScope

        local camera = Workspace.CurrentCamera
        if not camera then
                return {
			available = false,
			reason = "CurrentCamera is nil",
		}
	end

	local includeCFrame = boolDefault(resolvedScope.includeCFrame, true)
	local includeFocus = boolDefault(resolvedScope.includeFocus, true)
	local includeFieldOfView = boolDefault(resolvedScope.includeFieldOfView, true)

        local data: {
                available: true,
                cframe: Types.InspectCameraFrame?,
                focus: Types.InspectCameraFrame?,
                fieldOfView: number?,
        } = {
                available = true,
        }

        if includeCFrame then
                data.cframe = cframeToTable(camera.CFrame)
	end

	if includeFocus then
		data.focus = cframeToTable(camera.Focus)
	end

	if includeFieldOfView then
		data.fieldOfView = camera.FieldOfView
	end

        return data :: Types.InspectCameraResult
end

local function gatherServiceCounts(scope: Types.InspectServicesScope?): Types.InspectServicesResult
        local resolvedScope: Types.InspectServicesScope = (scope or {}) :: Types.InspectServicesScope

        local includeCounts = boolDefault(resolvedScope.includeCounts, true)
        local serviceNames = resolvedScope.services or DEFAULT_SERVICES

        local serviceDetails: Types.InspectServicesMap = {}
        for _, serviceName in serviceNames do
                local success, service = pcall(game.GetService, game, serviceName)
                if success and service then
                        serviceDetails[serviceName] = if includeCounts
                                then #service:GetDescendants()
				else "available"
		else
			serviceDetails[serviceName] = "unavailable"
		end
	end

	return {
		includeCounts = includeCounts,
		services = serviceDetails,
	}
end

local function handleInspectEnvironment(args: Types.ToolArgs): string?
	if args.tool ~= "InspectEnvironment" then
		return nil
	end

	local params = args.params
	if type(params) ~= "table" then
		error("Missing params in InspectEnvironment payload")
	end

	if params.selection ~= nil and type(params.selection) ~= "table" then
		error("Invalid selection scope in InspectEnvironment params")
	end
	if params.camera ~= nil and type(params.camera) ~= "table" then
		error("Invalid camera scope in InspectEnvironment params")
	end
	if params.services ~= nil and type(params.services) ~= "table" then
		error("Invalid services scope in InspectEnvironment params")
	end

        local selection = gatherSelection(params.selection)
        local camera = gatherCamera(params.camera)
        local services = gatherServiceCounts(params.services)

        local payload: Types.InspectEnvironmentResponse = {
                selection = selection,
                camera = camera,
                services = services,
                metadata = {
                        generatedAt = DateTime.now():ToIsoDateTime(),
		},
	}

	return HttpService:JSONEncode(payload)
end

return handleInspectEnvironment :: Types.ToolFunction
