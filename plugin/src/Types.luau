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

export type DiagnosticsLogOptions = {
        includeErrors: boolean?,
        includeWarnings: boolean?,
        includeInfo: boolean?,
        maxEntries: number?,
        chunkSize: number?,
}

export type DiagnosticsServiceSelection = {
        services: { string }?,
        includeDescendantCounts: boolean?,
        includeMemoryTags: boolean?,
}

export type DiagnosticsAndMetricsArgs = {
        logs: DiagnosticsLogOptions?,
        includeMicroProfiler: boolean?,
        includeMemoryStats: boolean?,
        includeTaskScheduler: boolean?,
        serviceSelection: DiagnosticsServiceSelection?,
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

export type DiagnosticsAndMetricsToolArgs = {
        tool: "DiagnosticsAndMetrics",
        params: DiagnosticsAndMetricsArgs,
}

export type ApplyInstanceOperationsToolArgs = {
        tool: "ApplyInstanceOperations",
        params: ApplyInstanceOperationsArgs,
}

export type ManageScriptsToolArgs = {
        tool: "ManageScripts",
        params: ManageScriptsArgs,
}

export type TestAndPlayAction = "play_solo" | "stop" | "run_tests" | "run_playtest"

export type TestAndPlayControlOptions = {
        timeoutSeconds: number?,
        pollIntervalSeconds: number?,
        testNames: { string }?,
        runAsync: boolean?,
        includeLogHistory: boolean?,
}

export type TestAndPlayControlArgs = {
        action: TestAndPlayAction,
        options: TestAndPlayControlOptions?,
}

export type TestAndPlayControlToolArgs = {
        tool: "TestAndPlayControl",
        params: TestAndPlayControlArgs,
}

export type AssetCollisionStrategy = "rename" | "overwrite" | "skip"

export type AssetPlacementMode = "camera" | "origin" | "preserve" | "custom_cframe"

export type AssetPlacementOptions = {
        mode: AssetPlacementMode,
        cframeComponents: { number }?,
}

export type PackagePublishRequest = {
        packageName: string,
        description: string?,
        groupId: number?,
        allowOverwrite: boolean?,
        allowComments: boolean?,
        tags: { string }?,
}

export type AssetPipelineSearchMarketplace = {
        action: "search_marketplace",
        query: string,
        limit: number?,
        creatorName: string?,
}

export type AssetPipelineInsertAssetVersion = {
        action: "insert_asset_version",
        assetId: number?,
        assetVersionId: number,
        desiredName: string?,
        targetParentPath: InstancePath?,
        collisionStrategy: AssetCollisionStrategy?,
        placement: AssetPlacementOptions?,
        saveAsPackage: PackagePublishRequest?,
}

export type AssetPipelineImportRbxm = {
        action: "import_rbxm",
        filePath: string,
        desiredName: string?,
        targetParentPath: InstancePath?,
        collisionStrategy: AssetCollisionStrategy?,
        placement: AssetPlacementOptions?,
        saveAsPackage: PackagePublishRequest?,
}

export type AssetPipelinePublishPackage = {
        action: "publish_package",
        instancePath: InstancePath,
        publish: PackagePublishRequest,
}

export type AssetPipelineOperation =
        AssetPipelineSearchMarketplace
        | AssetPipelineInsertAssetVersion
        | AssetPipelineImportRbxm
        | AssetPipelinePublishPackage

export type AssetPipelineRequest = {
        operations: { AssetPipelineOperation },
        defaultParentPath: InstancePath?,
        defaultCollisionStrategy: AssetCollisionStrategy?,
        defaultPlacement: AssetPlacementOptions?,
}

export type AssetPipelineOperationResult = {
        action: "search_marketplace" | "insert_asset_version" | "import_rbxm" | "publish_package",
        success: boolean,
        status: string,
        message: string?,
        details: { [string]: any }?,
}

export type AssetPipelineResponse = {
        results: { AssetPipelineOperationResult },
        summary: string?,
}

export type AssetPipelineToolArgs = {
        tool: "AssetPipeline",
        params: AssetPipelineRequest,
}

export type ToolFunction = (ToolArgs) -> string?

return {}
