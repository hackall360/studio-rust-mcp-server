export type InsertModelArgs = {
        query: string,
}

export type RunCodeArgs = {
        command: string,
}

export type InspectSelectionScope = {
        includeNames: boolean?,
        includeClassNames: boolean?,
        includeFullNames: boolean?,
}

export type InspectCameraScope = {
        includeCFrame: boolean?,
        includeFocus: boolean?,
        includeFieldOfView: boolean?,
}

export type InspectServicesScope = {
        includeCounts: boolean?,
        services: { string }?,
}

export type InspectEnvironmentArgs = {
        selection: InspectSelectionScope?,
        camera: InspectCameraScope?,
        services: InspectServicesScope?,
}

export type ToolArgs = {
        tool: string,
        params: any,
}

export type InsertModelToolArgs = {
        tool: "InsertModel",
        params: InsertModelArgs,
}

export type RunCodeToolArgs = {
        tool: "RunCode",
        params: RunCodeArgs,
}

export type InspectEnvironmentToolArgs = {
        tool: "InspectEnvironment",
        params: InspectEnvironmentArgs,
}

export type ToolFunction = (ToolArgs) -> string?

return {}
