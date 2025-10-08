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

export type ScriptPath = { string }

export type ScriptMetadataRequest = {
        includeClassName: boolean?,
        includeFullName: boolean?,
        includeParentPath: boolean?,
        includeRunContext: boolean?,
        includeAttributes: boolean?,
}

export type ScriptMetadata = {
        className: string?,
        fullName: string?,
        parentPath: ScriptPath?,
        runContext: string?,
        attributes: { [string]: any }?,
}

export type ScriptDiagnostic = {
        kind: string?,
        message: string,
        line: number?,
        column: number?,
}

export type ManageScriptOperationCreate = {
        action: "create",
        path: ScriptPath,
        scriptType: "Script" | "LocalScript" | "ModuleScript",
        source: string?,
        runContext: string?,
        attributes: { [string]: any }?,
        metadata: ScriptMetadataRequest?,
}

export type ManageScriptOperationGetSource = {
        action: "get_source",
        path: ScriptPath,
        metadata: ScriptMetadataRequest?,
}

export type ManageScriptOperationSetSource = {
        action: "set_source",
        path: ScriptPath,
        source: string,
        metadata: ScriptMetadataRequest?,
}

export type ManageScriptOperationRename = {
        action: "rename",
        path: ScriptPath,
        newName: string,
        metadata: ScriptMetadataRequest?,
}

export type ManageScriptOperation =
        ManageScriptOperationCreate
        | ManageScriptOperationGetSource
        | ManageScriptOperationSetSource
        | ManageScriptOperationRename

export type ManageScriptsArgs = {
        operations: { ManageScriptOperation },
        defaultMetadata: ScriptMetadataRequest?,
}

export type ManageScriptOperationResult = {
        action: "create" | "get_source" | "set_source" | "rename",
        path: ScriptPath,
        success: boolean,
        message: string?,
        source: string?,
        metadata: ScriptMetadata?,
        details: { [string]: any }?,
        diagnostics: { ScriptDiagnostic }?,
}

export type ManageScriptsResponse = {
        results: { ManageScriptOperationResult },
        summary: string?,
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

export type ManageScriptsToolArgs = {
        tool: "ManageScripts",
        params: ManageScriptsArgs,
}

export type ToolFunction = (ToolArgs) -> string?

return {}
