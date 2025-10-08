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

export type InstancePath = { string }

export type InstanceOperationAction = "create" | "update" | "delete"

export type PropertyMap = { [string]: any }

export type ApplyInstanceOperation = {
        action: InstanceOperationAction,
        path: InstancePath,
        properties: PropertyMap?,
        className: string?,
        name: string?,
}

export type ApplyInstanceOperationsArgs = {
        operations: { ApplyInstanceOperation },
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

export type ApplyInstanceOperationsToolArgs = {
        tool: "ApplyInstanceOperations",
        params: ApplyInstanceOperationsArgs,
}

export type ToolFunction = (ToolArgs) -> string?

return {}
