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

export type InspectSelectionItem = {
        name: string?,
        className: string?,
        fullName: string?,
}

export type InspectSelectionResult = {
        total: number,
        items: { InspectSelectionItem },
}

export type Vector3Record = { x: number, y: number, z: number }

export type InspectCameraFrame = {
        position: Vector3Record,
        lookVector: Vector3Record,
        upVector: Vector3Record,
        rightVector: Vector3Record,
}

export type InspectCameraResult =
        ({
                available: true,
                cframe: InspectCameraFrame?,
                focus: InspectCameraFrame?,
                fieldOfView: number?,
        })
        | ({
                available: false,
                reason: string,
        })

export type InspectServicesMap = { [string]: number | string }

export type InspectServicesResult = {
        includeCounts: boolean,
        services: InspectServicesMap,
}

export type InspectEnvironmentResponse = {
        selection: InspectSelectionResult,
        camera: InspectCameraResult,
        services: InspectServicesResult,
        metadata: {
                generatedAt: string,
        },
}

export type Color3Components = { r: number, g: number, b: number }

export type LightingSettings = {
        ambient: Color3Components?,
        outdoorAmbient: Color3Components?,
        brightness: number?,
        clockTime: number?,
        fogColor: Color3Components?,
        fogStart: number?,
        fogEnd: number?,
        technology: string?,
}

export type AtmosphereSettings = {
        density: number?,
        offset: number?,
        color: Color3Components?,
        decay: Color3Components?,
        glare: number?,
        haze: number?,
}

export type SkySettings = {
        skyboxBk: string?,
        skyboxDn: string?,
        skyboxFt: string?,
        skyboxLf: string?,
        skyboxRt: string?,
        skyboxUp: string?,
        sunTextureId: string?,
        moonTextureId: string?,
        starCount: number?,
        celestialBodiesShown: boolean?,
}

export type TerrainWaterSettings = {
        waterColor: Color3Components?,
        waterTransparency: number?,
        waterWaveSize: number?,
        waterWaveSpeed: number?,
}

export type SoundServiceSettings = {
        ambientReverb: string?,
        respectFilteringEnabled: boolean?,
        dopplerScale: number?,
        rolloffScale: number?,
}

export type SoundInstanceControl = {
        path: InstancePath,
        soundId: string?,
        volume: number?,
        playbackSpeed: number?,
        looped: boolean?,
        play: boolean?,
        stop: boolean?,
        timePosition: number?,
}

export type PostProcessingBaseEdit = {
        effect: string,
        name: string?,
        enabled: boolean?,
}

export type BloomEffectEdit = PostProcessingBaseEdit & {
        effect: "bloom",
        intensity: number?,
        size: number?,
        threshold: number?,
}

export type ColorCorrectionEffectEdit = PostProcessingBaseEdit & {
        effect: "color_correction",
        brightness: number?,
        contrast: number?,
        saturation: number?,
        tintColor: Color3Components?,
}

export type DepthOfFieldEffectEdit = PostProcessingBaseEdit & {
        effect: "depth_of_field",
        focusDistance: number?,
        inFocusRadius: number?,
        nearIntensity: number?,
        farIntensity: number?,
}

export type SunRaysEffectEdit = PostProcessingBaseEdit & {
        effect: "sun_rays",
        intensity: number?,
        spread: number?,
}

export type BlurEffectEdit = PostProcessingBaseEdit & {
        effect: "blur",
        size: number?,
}

export type PostProcessingEffectEdit =
        BloomEffectEdit
        | ColorCorrectionEffectEdit
        | DepthOfFieldEffectEdit
        | SunRaysEffectEdit
        | BlurEffectEdit

export type EnvironmentControlRequest = {
        lighting: LightingSettings?,
        atmosphere: AtmosphereSettings?,
        sky: SkySettings?,
        postProcessing: { PostProcessingEffectEdit }?,
        terrainWater: TerrainWaterSettings?,
        soundService: SoundServiceSettings?,
        sounds: { SoundInstanceControl }?,
}

export type EnvironmentControlResponse = {
        success: boolean,
        summary: string?,
        changes: { string }?,
        errors: { string }?,
}

export type EditorSessionSetSelectionAction = {
        action: "set_selection",
        paths: { InstancePath },
}

export type EditorSessionFocusCameraAction = {
        action: "focus_camera",
        cframeComponents: CFrameComponents?,
        focusComponents: CFrameComponents?,
        fieldOfView: number?,
}

export type EditorSessionFrameInstancesAction = {
        action: "frame_instances",
        paths: { InstancePath },
        tweenSeconds: number?,
}

export type EditorSessionOpenScriptAction = {
        action: "open_script",
        path: InstancePath,
        line: number?,
        column: number?,
        focus: boolean?,
}

export type EditorSessionControlArgs =
        EditorSessionSetSelectionAction
        | EditorSessionFocusCameraAction
        | EditorSessionFrameInstancesAction
        | EditorSessionOpenScriptAction

export type EditorSessionControlResponse = {
        action: string,
        success: boolean,
        message: string?,
        affectedInstances: number?,
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

export type Vector3Components = { number }
export type RegionCornerComponents = { number }
export type CFrameComponents = { number }

export type TerrainPivotMode = "active_camera"

export type TerrainPivotPlacement = {
        mode: TerrainPivotMode?,
        offset: Vector3Components?,
}

export type TerrainFillBlockOperation = {
        operation: "fill_block",
        cframeComponents: CFrameComponents,
        size: Vector3Components,
        material: string,
        occupancy: number?,
        pivotRelative: boolean?,
}

export type TerrainFillRegionOperation = {
        operation: "fill_region",
        cornerMin: RegionCornerComponents,
        cornerMax: RegionCornerComponents,
        material: string,
        resolution: number?,
        pivotRelative: boolean?,
}

export type TerrainReplaceMaterialOperation = {
        operation: "replace_material",
        sourceMaterial: string,
        targetMaterial: string,
        cornerMin: RegionCornerComponents,
        cornerMax: RegionCornerComponents,
        resolution: number?,
        pivotRelative: boolean?,
}

export type TerrainClearRegionOperation = {
        operation: "clear_region",
        cornerMin: RegionCornerComponents?,
        cornerMax: RegionCornerComponents?,
        resolution: number?,
        pivotRelative: boolean?,
}

export type TerrainConvertToTerrainOperation = {
        operation: "convert_to_terrain",
        paths: { InstancePath },
        resolution: number?,
        targetMaterial: string?,
}

export type TerrainOperation =
        TerrainFillBlockOperation
        | TerrainFillRegionOperation
        | TerrainReplaceMaterialOperation
        | TerrainClearRegionOperation
        | TerrainConvertToTerrainOperation

export type TerrainOperationsRequest = {
        operations: { TerrainOperation },
        pivot: TerrainPivotPlacement?,
}

export type TerrainOperationResult = {
        index: number,
        operation: "fill_block" | "fill_region" | "replace_material" | "clear_region" | "convert_to_terrain",
        success: boolean,
        message: string?,
        details: { [string]: any }?,
}

export type TerrainOperationsResponse = {
        results: { TerrainOperationResult },
        summary: string?,
        writeOccurred: boolean,
}

export type InstancePath = { string }

export type AttributeMap = { [string]: any }

export type CollectionListTagsOperation = {
        operation: "list_tags",
        paths: { InstancePath },
        includeAttributes: boolean?,
}

export type CollectionAddTagsOperation = {
        operation: "add_tags",
        paths: { InstancePath },
        tags: { string },
}

export type CollectionRemoveTagsOperation = {
        operation: "remove_tags",
        paths: { InstancePath },
        tags: { string },
}

export type CollectionSyncAttributesOperation = {
        operation: "sync_attributes",
        paths: { InstancePath },
        attributes: AttributeMap,
        clearMissing: boolean?,
}

export type CollectionQueryByTagOperation = {
        operation: "query_by_tag",
        tag: string,
        includeAttributes: boolean?,
        includePaths: boolean?,
}

export type CollectionAndAttributesOperation =
        CollectionListTagsOperation
        | CollectionAddTagsOperation
        | CollectionRemoveTagsOperation
        | CollectionSyncAttributesOperation
        | CollectionQueryByTagOperation

export type CollectionAndAttributesRequest = {
        operations: { CollectionAndAttributesOperation },
}

export type CollectionAndAttributesOperationResult = {
        index: number,
        operation: "list_tags" | "add_tags" | "remove_tags" | "sync_attributes" | "query_by_tag",
        success: boolean,
        message: string?,
        details: { [string]: any }?,
}

export type CollectionAndAttributesResponse = {
        results: { CollectionAndAttributesOperationResult },
        summary: string?,
        writeOccurred: boolean,
        affectedInstances: number?,
}

export type PhysicsAgentParameters = {
        agentRadius: number?,
        agentHeight: number?,
        agentCanJump: boolean?,
        agentMaxSlope: number?,
}

export type PhysicsCreateCollisionGroupOperation = {
        operation: "create_collision_group",
        groupName: string,
        replaceExisting: boolean?,
        active: boolean?,
}

export type PhysicsSetCollisionEnabledOperation = {
        operation: "set_collision_enabled",
        groupA: string,
        groupB: string,
        collidable: boolean,
        groupAActive: boolean?,
        groupBActive: boolean?,
}

export type PhysicsAssignPartToGroupOperation = {
        operation: "assign_part_to_group",
        path: InstancePath,
        groupName: string,
}

export type PhysicsComputePathOperation = {
        operation: "compute_path",
        startPosition: Vector3Record,
        targetPosition: Vector3Record,
        agentParameters: PhysicsAgentParameters?,
}

export type PhysicsAndNavigationOperation =
        PhysicsCreateCollisionGroupOperation
        | PhysicsSetCollisionEnabledOperation
        | PhysicsAssignPartToGroupOperation
        | PhysicsComputePathOperation

export type PhysicsWaypoint = {
        position: Vector3Record,
        action: string,
        label: string?,
}

export type PhysicsAndNavigationOperationResult = {
        index: number,
        operation:
                | "create_collision_group"
                | "set_collision_enabled"
                | "assign_part_to_group"
                | "compute_path",
        success: boolean,
        message: string?,
        details: { [string]: any }?,
}

export type PhysicsAndNavigationRequest = {
        operations: { PhysicsAndNavigationOperation },
}

export type PhysicsAndNavigationResponse = {
        results: { PhysicsAndNavigationOperationResult },
        summary: string?,
        writeOccurred: boolean,
}

export type InstanceOperationAction =
        "create"
        | "update"
        | "delete"
        | "reparent"
        | "clone"
        | "bulk_set_properties"

export type PropertyMap = { [string]: any }

export type AttributeMap = { [string]: any }

export type ApplyInstanceCreateOperation = {
        action: "create",
        path: InstancePath,
        className: string,
        name: string?,
        properties: PropertyMap?,
        attributes: AttributeMap?,
}

export type ApplyInstanceUpdateOperation = {
        action: "update",
        path: InstancePath,
        properties: PropertyMap?,
        attributes: AttributeMap?,
}

export type ApplyInstanceDeleteOperation = {
        action: "delete",
        path: InstancePath,
}

export type ApplyInstanceReparentOperation = {
        action: "reparent",
        path: InstancePath,
        newParentPath: InstancePath,
        name: string?,
        properties: PropertyMap?,
        attributes: AttributeMap?,
}

export type ApplyInstanceCloneOperation = {
        action: "clone",
        path: InstancePath,
        cloneCount: number?,
        newParentPath: InstancePath?,
        name: string?,
        properties: PropertyMap?,
        attributes: AttributeMap?,
}

export type ApplyInstanceBulkSetPropertiesOperation = {
        action: "bulk_set_properties",
        targetPaths: { InstancePath },
        properties: PropertyMap?,
        attributes: AttributeMap?,
        path: InstancePath?,
}

export type ApplyInstanceOperation =
        ApplyInstanceCreateOperation
        | ApplyInstanceUpdateOperation
        | ApplyInstanceDeleteOperation
        | ApplyInstanceReparentOperation
        | ApplyInstanceCloneOperation
        | ApplyInstanceBulkSetPropertiesOperation

export type ApplyInstanceOperationsArgs = {
        operations: { ApplyInstanceOperation },
}

export type ApplyInstanceOperationResult = {
        index: number,
        action: InstanceOperationAction,
        path: InstancePath,
        paths: { InstancePath }?,
        success: boolean,
        message: string?,
}

export type ApplyInstanceOperationsResponse = {
        results: { ApplyInstanceOperationResult },
        summary: string?,
        writeOccurred: boolean,
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
        details: { [string]: any }?, -- e.g. characters, previousCharacters, parentFullName, previousPath
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

export type TerrainOperationsToolArgs = {
        tool: "TerrainOperations",
        params: TerrainOperationsRequest,
}

export type CollectionAndAttributesToolArgs = {
        tool: "CollectionAndAttributes",
        params: CollectionAndAttributesRequest,
}

export type PhysicsAndNavigationToolArgs = {
        tool: "PhysicsAndNavigation",
        params: PhysicsAndNavigationRequest,
}

export type EnvironmentControlToolArgs = {
        tool: "EnvironmentControl",
        params: EnvironmentControlRequest,
}

export type ApplyInstanceOperationsToolArgs = {
        tool: "ApplyInstanceOperations",
        params: ApplyInstanceOperationsArgs,
}

export type ManageScriptsToolArgs = {
        tool: "ManageScripts",
        params: ManageScriptsArgs,
}

export type EditorSessionControlToolArgs = {
        tool: "EditorSessionControl",
        params: EditorSessionControlArgs,
}

export type TestAndPlayAction =
        "play_solo"
        | "stop"
        | "run_tests"
        | "run_playtest"
        | "send_input"
        | "capture_stats"

export type TestAndPlayInputWaitStep = {
        kind: "wait",
        seconds: number,
}

export type TestAndPlayInputKeyStep = {
        kind: "key",
        keyCode: string,
        isDown: boolean?,
        isRepeat: boolean?,
        text: string?,
        delaySeconds: number?,
}

export type TestAndPlayInputMouseButtonStep = {
        kind: "mouse_button",
        x: number?,
        y: number?,
        button: string,
        isDown: boolean?,
        moveMouse: boolean?,
        delaySeconds: number?,
}

export type TestAndPlayInputMouseMoveStep = {
        kind: "mouse_move",
        x: number?,
        y: number?,
        deltaX: number?,
        deltaY: number?,
        delaySeconds: number?,
}

export type TestAndPlayInputStep =
        TestAndPlayInputWaitStep
        | TestAndPlayInputKeyStep
        | TestAndPlayInputMouseButtonStep
        | TestAndPlayInputMouseMoveStep

export type TestAndPlayTelemetryFlags = {
        includeRunState: boolean?,
        includeLocalPlayerPosition: boolean?,
        includeGuiVisibility: boolean?,
}

export type TestAndPlayControlOptions = {
        timeoutSeconds: number?,
        pollIntervalSeconds: number?,
        testNames: { string }?,
        runAsync: boolean?,
        includeLogHistory: boolean?,
        inputSequence: { TestAndPlayInputStep }?,
        watchTargets: { string }?,
        telemetry: TestAndPlayTelemetryFlags?,
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
