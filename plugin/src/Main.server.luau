local Main = script:FindFirstAncestor("MCPStudioPlugin")
local MockWebSocketService = require(Main.MockWebSocketService)
local Types = require(Main.Types)

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local StudioService = game:GetService("StudioService")

local URI = "http://localhost:44755"
local RECEIVE_ENDPOINT = "/request"
local SEND_ENDPOINT = "/response"

if RunService:IsRunning() then
	return
end

local old_warn = warn
local function log(...)
	if false then
		old_warn(...)
	end
end

local function fetchBuiltinTools()
        local tools = {}
        for _, tool in Main.Tools:GetChildren() do
                if tool:IsA("ModuleScript") then
                        table.insert(tools, require(tool) :: Types.ToolFunction)
                end
        end
        return tools
end

local tools = fetchBuiltinTools()

local function shouldRecordHistoryForRequest(args: Types.ToolArgs): boolean
        if args.tool == "InspectEnvironment"
                or args.tool == "DiagnosticsAndMetrics"
                or args.tool == "ApplyInstanceOperations"
                or args.tool == "TestAndPlayControl"
                or args.tool == "EditorSessionControl"
        then
                return false
        end

        if args.tool == "ManageScripts" then
                local params = args.params
                if type(params) == "table" then
                        local operations = params.operations
                        if type(operations) == "table" then
                                for _, operation in operations do
                                        if type(operation) == "table" then
                                                local action = operation.action
                                                if action ~= "get_source" then
                                                        return true
                                                end
                                        end
                                end
                                return false
                        end
                end
        end

        if args.tool == "AssetPipeline" then
                local params = args.params
                if type(params) == "table" then
                        local operations = params.operations
                        if type(operations) == "table" then
                                for _, operation in operations do
                                        if type(operation) == "table" then
                                                local action = operation.action
                                                if action ~= "search_marketplace" then
                                                        return true
                                                end
                                        end
                                end
                                return false
                        end
                end
        end

        if args.tool == "CollectionAndAttributes" then
                local params = args.params
                if type(params) == "table" then
                        local operations = params.operations
                        if type(operations) == "table" then
                                for _, operation in operations do
                                        if type(operation) == "table" then
                                                local operationName = operation.operation
                                                if operationName == "add_tags"
                                                        or operationName == "remove_tags"
                                                        or operationName == "sync_attributes"
                                                then
                                                        return true
                                                end
                                        end
                                end
                                return false
                        end
                end
                return false
        end

        return true
end

local function connectWebSocket()
	local client = MockWebSocketService:CreateClient(URI)
	client:SetReceiveEndpoint(RECEIVE_ENDPOINT)
	client:SetSendEndpoint(SEND_ENDPOINT)

	client.Opened:Once(function()
		log("[MCP] Connection opened")
	end)

	client.Closed:Once(function()
		log("[MCP] Connection closed")
	end)

	client.MessageReceived:Connect(function(message)
		log("[MCP] Message received")

		local body = HttpService:JSONDecode(message)
		assert(body and body.id and body.args, "Invalid message received")
		assert(type(body.args) == "table", "Invalid message args payload")
		assert(type(body.args.tool) == "string", "Missing tool identifier in payload")
		assert(body.args.params ~= nil, "Missing params in payload")
		assert(type(body.args.params) == "table", "Invalid params payload")

		local args: Types.ToolArgs = body.args
		local id: string = body.id
		local responseSent = false
		local function sendResponseOnce(response: string)
			if not responseSent then
				log("[MCP] Sending response:" .. response)
				responseSent = true
				client:Send({
					id = id,
					response = response,
				})
				if args.tool == "InspectEnvironment" then
					log("[MCP] Inspection response sent to MCP client")
				end
			end
		end

                local shouldRecordHistory = shouldRecordHistoryForRequest(args)
                local recording = if shouldRecordHistory
                        then ChangeHistoryService:TryBeginRecording("StudioMCP")
                        else nil
                local historyWriteOccurred = false

                for _, tool in tools do
                        local success, response = pcall(tool, args)

                        if success and response then
                                if shouldRecordHistory and not historyWriteOccurred then
                                        if args.tool == "TerrainOperations" or args.tool == "CollectionAndAttributes" then
                                                local ok, decoded = pcall(HttpService.JSONDecode, HttpService, response)
                                                if ok
                                                        and type(decoded) == "table"
                                                        and decoded.writeOccurred == true
                                                then
                                                        historyWriteOccurred = true
                                                end
                                        else
                                                historyWriteOccurred = true
                                        end
                                end
                                sendResponseOnce(response)
                                if args.tool == "InspectEnvironment" then
                                        log("[MCP] Inspection response returned")
                                end
                        elseif not success then
				sendResponseOnce("Error handling request: " .. tostring(response))
			end
		end

                if recording then
                        local finishMode = if historyWriteOccurred
                                then Enum.FinishRecordingOperation.Commit
                                else Enum.FinishRecordingOperation.Cancel
                        ChangeHistoryService:FinishRecording(recording, finishMode)
                end

		sendResponseOnce("No tool found to handle request")
		log("[MCP] Successfully handled request")
	end)

	return client
end

local function getButtonImage()
	local ok, response = pcall(function()
		return StudioService:GetClassIcon("PackageLink").Image
	end)
	return ok and response or "rbxasset://textures/ui/GuiImagePlaceholder.png"
end

local currentClient: MockWebSocketService.MockWebSocketClient? = connectWebSocket() -- nil for default off
print("The MCP Studio plugin is ready for prompts.")

local toolbar = plugin:CreateToolbar("MCP")
local toggleButton = toolbar:CreateButton("Toggle MCP", "Toggle connection to the server", getButtonImage())
toggleButton.ClickableWhenViewportHidden = true
toggleButton:SetActive(currentClient ~= nil)

toggleButton.Click:Connect(function()
	if not currentClient then
		currentClient = connectWebSocket()
		print("The MCP Studio plugin is ready for prompts.")
	else
		currentClient:Close()
		currentClient = nil
		print("The MCP Studio plugin is stopped.")
	end
end)
