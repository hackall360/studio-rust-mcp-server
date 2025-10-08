local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Terrain = Workspace.Terrain

local SECTION_SUMMARY_LABELS = {
        lighting = "lighting",
        atmosphere = "atmosphere",
        sky = "sky",
        post_processing = "post-processing",
        terrain = "terrain water",
        sound_service = "SoundService",
        sounds = "sound instances",
}

type EnvironmentControlRequest = Types.EnvironmentControlRequest
type EnvironmentControlResponse = Types.EnvironmentControlResponse
type LightingSettings = Types.LightingSettings
type AtmosphereSettings = Types.AtmosphereSettings
type SkySettings = Types.SkySettings
type TerrainWaterSettings = Types.TerrainWaterSettings
type SoundServiceSettings = Types.SoundServiceSettings
type SoundInstanceControl = Types.SoundInstanceControl
type PostProcessingEffectEdit = Types.PostProcessingEffectEdit
type Color3Components = Types.Color3Components

type ToolArgs = Types.ToolArgs

type SectionSet = { [string]: boolean }

local function jsonEncode(payload: EnvironmentControlResponse): string
        return HttpService:JSONEncode(payload)
end

local function isFiniteNumber(value: any): boolean
        return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function parseNumber(value: any, name: string, minValue: number?, maxValue: number?): (number?, string?)
        if not isFiniteNumber(value) then
                return nil, string.format("%s must be a finite number", name)
        end
        local numeric = value :: number
        if minValue and numeric < minValue then
                return nil, string.format("%s must be >= %s", name, tostring(minValue))
        end
        if maxValue and numeric > maxValue then
                return nil, string.format("%s must be <= %s", name, tostring(maxValue))
        end
        return numeric, nil
end

local function parseColor(components: Color3Components?, context: string): (Color3?, string?)
        if type(components) ~= "table" then
                return nil, string.format("%s must be an object with r, g, b fields", context)
        end

        local r = components.r
        local g = components.g
        local b = components.b

        if not isFiniteNumber(r) then
                return nil, string.format("%s.r must be a finite number", context)
        end
        if not isFiniteNumber(g) then
                return nil, string.format("%s.g must be a finite number", context)
        end
        if not isFiniteNumber(b) then
                return nil, string.format("%s.b must be a finite number", context)
        end

        local function normaliseChannel(value: number): number
                if value > 1 then
                        return math.clamp(value / 255, 0, 1)
                end
                if value < 0 then
                        return 0
                end
                if value > 1 then
                        return 1
                end
                return value
        end

        return Color3.new(normaliseChannel(r), normaliseChannel(g), normaliseChannel(b)), nil
end

local function formatColor(color: Color3): string
        return string.format("(%.3f, %.3f, %.3f)", color.R, color.G, color.B)
end

local function recordChange(changes: { string }, sections: SectionSet, section: string, message: string)
        table.insert(changes, message)
        sections[section] = true
end

local function normalisePath(path: Types.InstancePath?): { string }
        local normalised = {}
        if type(path) ~= "table" then
                return normalised
        end

        for _, segment in path do
                if type(segment) == "string" and segment ~= "" and segment ~= "game" and segment ~= "DataModel" then
                        table.insert(normalised, segment)
                end
        end

        return normalised
end

local function resolveInstance(path: Types.InstancePath?): (Instance?, string?)
        local normalised = normalisePath(path)
        if #normalised == 0 then
                return nil, "A non-empty instance path is required"
        end

        local current: Instance = game
        for index, segment in normalised do
                local nextInstance = current:FindFirstChild(segment)
                if not nextInstance then
                        local parentName = if index == 1 then "game" else current:GetFullName()
                        return nil, string.format("Unable to find '%s' under %s", segment, parentName)
                end
                current = nextInstance
        end

        return current, nil
end

local function matchEnumItem(enum: Enum, name: string?, context: string): (EnumItem?, string?)
        if type(name) ~= "string" or name == "" then
                return nil, string.format("%s must be a non-empty string", context)
        end

        local candidate = enum[name]
        if candidate then
                return candidate, nil
        end

        local lower = string.lower(name)
        for _, item in enum:GetEnumItems() do
                if string.lower(item.Name) == lower then
                        return item, nil
                end
        end

        return nil, string.format("Unknown %s '%s'", context, name)
end

local function applyLighting(settings: LightingSettings?, changes: { string }, sections: SectionSet): (boolean, string?)
        if settings == nil then
                return true, nil
        end
        if type(settings) ~= "table" then
                return false, "lighting settings must be an object"
        end

        local applied = false

        if settings.ambient ~= nil then
                local color, err = parseColor(settings.ambient, "lighting.ambient")
                if not color then
                        return false, err
                end
                Lighting.Ambient = color
                recordChange(changes, sections, "lighting", "Lighting.Ambient -> " .. formatColor(color))
                applied = true
        end

        if settings.outdoorAmbient ~= nil then
                local color, err = parseColor(settings.outdoorAmbient, "lighting.outdoorAmbient")
                if not color then
                        return false, err
                end
                Lighting.OutdoorAmbient = color
                recordChange(changes, sections, "lighting", "Lighting.OutdoorAmbient -> " .. formatColor(color))
                applied = true
        end

        if settings.brightness ~= nil then
                local value, err = parseNumber(settings.brightness, "lighting.brightness", 0, nil)
                if not value then
                        return false, err
                end
                Lighting.Brightness = value
                recordChange(changes, sections, "lighting", string.format("Lighting.Brightness -> %.3f", value))
                applied = true
        end

        if settings.clockTime ~= nil then
                local value, err = parseNumber(settings.clockTime, "lighting.clockTime", 0, 24)
                if not value then
                        return false, err
                end
                Lighting.ClockTime = value
                recordChange(changes, sections, "lighting", string.format("Lighting.ClockTime -> %.3f", value))
                applied = true
        end

        if settings.fogColor ~= nil then
                local color, err = parseColor(settings.fogColor, "lighting.fogColor")
                if not color then
                        return false, err
                end
                Lighting.FogColor = color
                recordChange(changes, sections, "lighting", "Lighting.FogColor -> " .. formatColor(color))
                applied = true
        end

        if settings.fogStart ~= nil then
                local value, err = parseNumber(settings.fogStart, "lighting.fogStart", 0, nil)
                if not value then
                        return false, err
                end
                Lighting.FogStart = value
                recordChange(changes, sections, "lighting", string.format("Lighting.FogStart -> %.3f", value))
                applied = true
        end

        if settings.fogEnd ~= nil then
                local value, err = parseNumber(settings.fogEnd, "lighting.fogEnd", 0, nil)
                if not value then
                        return false, err
                end
                Lighting.FogEnd = value
                recordChange(changes, sections, "lighting", string.format("Lighting.FogEnd -> %.3f", value))
                applied = true
        end

        if settings.technology ~= nil then
                local technology, err = matchEnumItem(Enum.Technology, settings.technology, "lighting.technology")
                if not technology then
                        return false, err
                end
                Lighting.Technology = technology
                recordChange(changes, sections, "lighting", "Lighting.Technology -> " .. technology.Name)
                applied = true
        end

        if applied then
                sections.lighting = true
        end

        return true, nil
end

local function ensureChildOfClass(parent: Instance, className: string, desiredName: string?): Instance
        if desiredName and desiredName ~= "" then
                local existing = parent:FindFirstChild(desiredName)
                if existing and existing:IsA(className) then
                        return existing
                end
        end

        local found = parent:FindFirstChildOfClass(className)
        if found then
                        if desiredName and desiredName ~= "" then
                                found.Name = desiredName
                        end
                        return found
        end

        local instance = Instance.new(className)
        instance.Name = desiredName or className
        instance.Parent = parent
        return instance
end

local function applyAtmosphere(settings: AtmosphereSettings?, changes: { string }, sections: SectionSet): (boolean, string?)
        if settings == nil then
                return true, nil
        end
        if type(settings) ~= "table" then
                return false, "atmosphere settings must be an object"
        end

        local atmosphere = ensureChildOfClass(Lighting, "Atmosphere", "MCPAtmosphere")
        local applied = false

        if settings.density ~= nil then
                local value, err = parseNumber(settings.density, "atmosphere.density", 0, 1)
                if not value then
                        return false, err
                end
                atmosphere.Density = value
                recordChange(changes, sections, "atmosphere", string.format("Atmosphere.Density -> %.3f", value))
                applied = true
        end

        if settings.offset ~= nil then
                local value, err = parseNumber(settings.offset, "atmosphere.offset", -1, 1)
                if not value then
                        return false, err
                end
                atmosphere.Offset = value
                recordChange(changes, sections, "atmosphere", string.format("Atmosphere.Offset -> %.3f", value))
                applied = true
        end

        if settings.glare ~= nil then
                local value, err = parseNumber(settings.glare, "atmosphere.glare", 0, 1)
                if not value then
                        return false, err
                end
                atmosphere.Glare = value
                recordChange(changes, sections, "atmosphere", string.format("Atmosphere.Glare -> %.3f", value))
                applied = true
        end

        if settings.haze ~= nil then
                local value, err = parseNumber(settings.haze, "atmosphere.haze", 0, 1)
                if not value then
                        return false, err
                end
                atmosphere.Haze = value
                recordChange(changes, sections, "atmosphere", string.format("Atmosphere.Haze -> %.3f", value))
                applied = true
        end

        if settings.color ~= nil then
                local color, err = parseColor(settings.color, "atmosphere.color")
                if not color then
                        return false, err
                end
                atmosphere.Color = color
                recordChange(changes, sections, "atmosphere", "Atmosphere.Color -> " .. formatColor(color))
                applied = true
        end

        if settings.decay ~= nil then
                local color, err = parseColor(settings.decay, "atmosphere.decay")
                if not color then
                        return false, err
                end
                atmosphere.Decay = color
                recordChange(changes, sections, "atmosphere", "Atmosphere.Decay -> " .. formatColor(color))
                applied = true
        end

        if applied then
                sections.atmosphere = true
        end

        return true, nil
end

local function applySky(settings: SkySettings?, changes: { string }, sections: SectionSet): (boolean, string?)
        if settings == nil then
                return true, nil
        end
        if type(settings) ~= "table" then
                return false, "sky settings must be an object"
        end

        local sky = ensureChildOfClass(Lighting, "Sky", "MCPSky")
        local applied = false

        local function assignStringProperty(propertyName: string, value: any, context: string)
                if type(value) ~= "string" then
                        return false, string.format("%s must be a string", context)
                end
                sky[propertyName] = value
                recordChange(changes, sections, "sky", string.format("Sky.%s -> %s", propertyName, value))
                return true, nil
        end

        if settings.skyboxBk ~= nil then
                local ok, err = assignStringProperty("SkyboxBk", settings.skyboxBk, "sky.skyboxBk")
                if not ok then
                        return false, err
                end
                applied = true
        end
        if settings.skyboxDn ~= nil then
                local ok, err = assignStringProperty("SkyboxDn", settings.skyboxDn, "sky.skyboxDn")
                if not ok then
                        return false, err
                end
                applied = true
        end
        if settings.skyboxFt ~= nil then
                local ok, err = assignStringProperty("SkyboxFt", settings.skyboxFt, "sky.skyboxFt")
                if not ok then
                        return false, err
                end
                applied = true
        end
        if settings.skyboxLf ~= nil then
                local ok, err = assignStringProperty("SkyboxLf", settings.skyboxLf, "sky.skyboxLf")
                if not ok then
                        return false, err
                end
                applied = true
        end
        if settings.skyboxRt ~= nil then
                local ok, err = assignStringProperty("SkyboxRt", settings.skyboxRt, "sky.skyboxRt")
                if not ok then
                        return false, err
                end
                applied = true
        end
        if settings.skyboxUp ~= nil then
                local ok, err = assignStringProperty("SkyboxUp", settings.skyboxUp, "sky.skyboxUp")
                if not ok then
                        return false, err
                end
                applied = true
        end
        if settings.sunTextureId ~= nil then
                local ok, err = assignStringProperty("SunTextureId", settings.sunTextureId, "sky.sunTextureId")
                if not ok then
                        return false, err
                end
                applied = true
        end
        if settings.moonTextureId ~= nil then
                local ok, err = assignStringProperty("MoonTextureId", settings.moonTextureId, "sky.moonTextureId")
                if not ok then
                        return false, err
                end
                applied = true
        end
        if settings.starCount ~= nil then
                local value, err = parseNumber(settings.starCount, "sky.starCount", 0, 6000)
                if not value then
                        return false, err
                end
                sky.StarCount = value
                recordChange(changes, sections, "sky", string.format("Sky.StarCount -> %.0f", value))
                applied = true
        end
        if settings.celestialBodiesShown ~= nil then
                if typeof(settings.celestialBodiesShown) ~= "boolean" then
                        return false, "sky.celestialBodiesShown must be a boolean"
                end
                sky.CelestialBodiesShown = settings.celestialBodiesShown
                recordChange(
                        changes,
                        sections,
                        "sky",
                        string.format("Sky.CelestialBodiesShown -> %s", tostring(settings.celestialBodiesShown))
                )
                applied = true
        end

        if applied then
                sections.sky = true
        end

        return true, nil
end

local function applyTerrainWater(settings: TerrainWaterSettings?, changes: { string }, sections: SectionSet): (boolean, string?)
        if settings == nil then
                return true, nil
        end
        if type(settings) ~= "table" then
                return false, "terrainWater settings must be an object"
        end

        local applied = false

        if settings.waterColor ~= nil then
                local color, err = parseColor(settings.waterColor, "terrainWater.waterColor")
                if not color then
                        return false, err
                end
                Terrain.WaterColor = color
                recordChange(changes, sections, "terrain", "Terrain.WaterColor -> " .. formatColor(color))
                applied = true
        end
        if settings.waterTransparency ~= nil then
                local value, err = parseNumber(settings.waterTransparency, "terrainWater.waterTransparency", 0, 1)
                if not value then
                        return false, err
                end
                Terrain.WaterTransparency = value
                recordChange(
                        changes,
                        sections,
                        "terrain",
                        string.format("Terrain.WaterTransparency -> %.3f", value)
                )
                applied = true
        end
        if settings.waterWaveSize ~= nil then
                local value, err = parseNumber(settings.waterWaveSize, "terrainWater.waterWaveSize", 0, nil)
                if not value then
                        return false, err
                end
                Terrain.WaterWaveSize = value
                recordChange(
                        changes,
                        sections,
                        "terrain",
                        string.format("Terrain.WaterWaveSize -> %.3f", value)
                )
                applied = true
        end
        if settings.waterWaveSpeed ~= nil then
                local value, err = parseNumber(settings.waterWaveSpeed, "terrainWater.waterWaveSpeed", 0, nil)
                if not value then
                        return false, err
                end
                Terrain.WaterWaveSpeed = value
                recordChange(
                        changes,
                        sections,
                        "terrain",
                        string.format("Terrain.WaterWaveSpeed -> %.3f", value)
                )
                applied = true
        end

        if applied then
                sections.terrain = true
        end

        return true, nil
end

local function applySoundService(settings: SoundServiceSettings?, changes: { string }, sections: SectionSet): (boolean, string?)
        if settings == nil then
                return true, nil
        end
        if type(settings) ~= "table" then
                return false, "soundService settings must be an object"
        end

        local applied = false

        if settings.ambientReverb ~= nil then
                local reverb, err = matchEnumItem(Enum.AmbientReverb, settings.ambientReverb, "soundService.ambientReverb")
                if not reverb then
                        return false, err
                end
                SoundService.AmbientReverb = reverb
                recordChange(changes, sections, "sound_service", "SoundService.AmbientReverb -> " .. reverb.Name)
                applied = true
        end

        if settings.respectFilteringEnabled ~= nil then
                if typeof(settings.respectFilteringEnabled) ~= "boolean" then
                        return false, "soundService.respectFilteringEnabled must be a boolean"
                end
                SoundService.RespectFilteringEnabled = settings.respectFilteringEnabled
                recordChange(
                        changes,
                        sections,
                        "sound_service",
                        string.format(
                                "SoundService.RespectFilteringEnabled -> %s",
                                tostring(settings.respectFilteringEnabled)
                        )
                )
                applied = true
        end

        if settings.dopplerScale ~= nil then
                local value, err = parseNumber(settings.dopplerScale, "soundService.dopplerScale", 0, nil)
                if not value then
                        return false, err
                end
                SoundService.DopplerScale = value
                recordChange(
                        changes,
                        sections,
                        "sound_service",
                        string.format("SoundService.DopplerScale -> %.3f", value)
                )
                applied = true
        end

        if settings.rolloffScale ~= nil then
                local value, err = parseNumber(settings.rolloffScale, "soundService.rolloffScale", 0, nil)
                if not value then
                        return false, err
                end
                SoundService.RolloffScale = value
                recordChange(
                        changes,
                        sections,
                        "sound_service",
                        string.format("SoundService.RolloffScale -> %.3f", value)
                )
                applied = true
        end

        if applied then
                sections.sound_service = true
        end

        return true, nil
end

local function applyPostProcessing(edit: PostProcessingEffectEdit, changes: { string }, sections: SectionSet): (boolean, string?)
        local effectType = (edit :: any).effect
        if type(effectType) ~= "string" then
                return false, "postProcessing entry missing effect discriminator"
        end

        local name = (edit :: any).name
        if name ~= nil and typeof(name) ~= "string" then
                return false, "postProcessing.name must be a string when provided"
        end

        local className
        if effectType == "bloom" then
                className = "BloomEffect"
        elseif effectType == "color_correction" then
                className = "ColorCorrectionEffect"
        elseif effectType == "depth_of_field" then
                className = "DepthOfFieldEffect"
        elseif effectType == "sun_rays" then
                className = "SunRaysEffect"
        elseif effectType == "blur" then
                className = "BlurEffect"
        else
                return false, string.format("Unsupported postProcessing effect '%s'", effectType)
        end

        local instance = ensureChildOfClass(Lighting, className, name)

        local applied = false
        local payload = edit :: any

        if payload.enabled ~= nil then
                if typeof(payload.enabled) ~= "boolean" then
                        return false, string.format("postProcessing.%s.enabled must be a boolean", effectType)
                end
                instance.Enabled = payload.enabled
                recordChange(
                        changes,
                        sections,
                        "post_processing",
                        string.format("%s.Enabled -> %s", instance.Name, tostring(payload.enabled))
                )
                applied = true
        end

        if effectType == "bloom" then
                if payload.intensity ~= nil then
                        local value, err = parseNumber(payload.intensity, "postProcessing.bloom.intensity", 0, nil)
                        if not value then
                                return false, err
                        end
                        instance.Intensity = value
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.Intensity -> %.3f", instance.Name, value)
                        )
                        applied = true
                end
                if payload.size ~= nil then
                        local value, err = parseNumber(payload.size, "postProcessing.bloom.size", 0, nil)
                        if not value then
                                return false, err
                        end
                        instance.Size = value
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.Size -> %.3f", instance.Name, value)
                        )
                        applied = true
                end
                if payload.threshold ~= nil then
                        local value, err = parseNumber(payload.threshold, "postProcessing.bloom.threshold", 0, 1)
                        if not value then
                                return false, err
                        end
                        instance.Threshold = value
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.Threshold -> %.3f", instance.Name, value)
                        )
                        applied = true
                end
        elseif effectType == "color_correction" then
                if payload.brightness ~= nil then
                        local value, err = parseNumber(payload.brightness, "postProcessing.color_correction.brightness", -1, 1)
                        if not value then
                                return false, err
                        end
                        instance.Brightness = value
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.Brightness -> %.3f", instance.Name, value)
                        )
                        applied = true
                end
                if payload.contrast ~= nil then
                        local value, err = parseNumber(payload.contrast, "postProcessing.color_correction.contrast", -1, 1)
                        if not value then
                                return false, err
                        end
                        instance.Contrast = value
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.Contrast -> %.3f", instance.Name, value)
                        )
                        applied = true
                end
                if payload.saturation ~= nil then
                        local value, err = parseNumber(payload.saturation, "postProcessing.color_correction.saturation", -1, 1)
                        if not value then
                                return false, err
                        end
                        instance.Saturation = value
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.Saturation -> %.3f", instance.Name, value)
                        )
                        applied = true
                end
                if payload.tintColor ~= nil then
                        local color, err = parseColor(payload.tintColor, "postProcessing.color_correction.tintColor")
                        if not color then
                                return false, err
                        end
                        instance.TintColor = color
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.TintColor -> %s", instance.Name, formatColor(color))
                        )
                        applied = true
                end
        elseif effectType == "depth_of_field" then
                if payload.focusDistance ~= nil then
                        local value, err = parseNumber(payload.focusDistance, "postProcessing.depth_of_field.focusDistance", 0, nil)
                        if not value then
                                return false, err
                        end
                        instance.FocusDistance = value
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.FocusDistance -> %.3f", instance.Name, value)
                        )
                        applied = true
                end
                if payload.inFocusRadius ~= nil then
                        local value, err = parseNumber(payload.inFocusRadius, "postProcessing.depth_of_field.inFocusRadius", 0, nil)
                        if not value then
                                return false, err
                        end
                        instance.InFocusRadius = value
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.InFocusRadius -> %.3f", instance.Name, value)
                        )
                        applied = true
                end
                if payload.nearIntensity ~= nil then
                        local value, err = parseNumber(payload.nearIntensity, "postProcessing.depth_of_field.nearIntensity", 0, 1)
                        if not value then
                                return false, err
                        end
                        instance.NearIntensity = value
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.NearIntensity -> %.3f", instance.Name, value)
                        )
                        applied = true
                end
                if payload.farIntensity ~= nil then
                        local value, err = parseNumber(payload.farIntensity, "postProcessing.depth_of_field.farIntensity", 0, 1)
                        if not value then
                                return false, err
                        end
                        instance.FarIntensity = value
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.FarIntensity -> %.3f", instance.Name, value)
                        )
                        applied = true
                end
        elseif effectType == "sun_rays" then
                if payload.intensity ~= nil then
                        local value, err = parseNumber(payload.intensity, "postProcessing.sun_rays.intensity", 0, 1)
                        if not value then
                                return false, err
                        end
                        instance.Intensity = value
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.Intensity -> %.3f", instance.Name, value)
                        )
                        applied = true
                end
                if payload.spread ~= nil then
                        local value, err = parseNumber(payload.spread, "postProcessing.sun_rays.spread", 0, 1)
                        if not value then
                                return false, err
                        end
                        instance.Spread = value
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.Spread -> %.3f", instance.Name, value)
                        )
                        applied = true
                end
        elseif effectType == "blur" then
                if payload.size ~= nil then
                        local value, err = parseNumber(payload.size, "postProcessing.blur.size", 0, 100)
                        if not value then
                                return false, err
                        end
                        instance.Size = value
                        recordChange(
                                changes,
                                sections,
                                "post_processing",
                                string.format("%s.Size -> %.3f", instance.Name, value)
                        )
                        applied = true
                end
        end

        if applied then
                sections.post_processing = true
        end

        return true, nil
end

local function applyPostProcessingBatch(edits: { PostProcessingEffectEdit }?, changes: { string }, sections: SectionSet): (boolean, string?)
        if edits == nil then
                return true, nil
        end
        if type(edits) ~= "table" then
                return false, "postProcessing must be an array"
        end

        for index, edit in edits do
                local success, err = applyPostProcessing(edit, changes, sections)
                if not success then
                        return false, string.format("postProcessing[%d]: %s", index, err)
                end
        end

        return true, nil
end

local function describeInstance(instance: Instance): string
        return instance:GetFullName()
end

local function applySoundTargets(targets: { SoundInstanceControl }?, changes: { string }, sections: SectionSet): (boolean, string?)
        if targets == nil then
                return true, nil
        end
        if type(targets) ~= "table" then
                return false, "sounds must be an array"
        end

        for index, control in targets do
                if type(control) ~= "table" then
                        return false, string.format("sounds[%d] must be an object", index)
                end

                local instance, resolveError = resolveInstance(control.path)
                if not instance then
                        return false, string.format("sounds[%d]: %s", index, resolveError or "unable to resolve path")
                end

                if not instance:IsA("Sound") then
                        return false, string.format(
                                "sounds[%d]: Resolved instance %s is not a Sound",
                                index,
                                describeInstance(instance)
                        )
                end

                local applied = false

                if control.soundId ~= nil then
                        if type(control.soundId) ~= "string" then
                                return false, string.format("sounds[%d].soundId must be a string", index)
                        end
                        instance.SoundId = control.soundId
                        recordChange(
                                changes,
                                sections,
                                "sounds",
                                string.format("%s.SoundId -> %s", describeInstance(instance), control.soundId)
                        )
                        applied = true
                end

                if control.volume ~= nil then
                        local value, err = parseNumber(control.volume, string.format("sounds[%d].volume", index), 0, nil)
                        if not value then
                                return false, err
                        end
                        instance.Volume = value
                        recordChange(
                                changes,
                                sections,
                                "sounds",
                                string.format("%s.Volume -> %.3f", describeInstance(instance), value)
                        )
                        applied = true
                end

                if control.playbackSpeed ~= nil then
                        local value, err = parseNumber(
                                control.playbackSpeed,
                                string.format("sounds[%d].playbackSpeed", index),
                                0.01,
                                nil
                        )
                        if not value then
                                return false, err
                        end
                        instance.PlaybackSpeed = value
                        recordChange(
                                changes,
                                sections,
                                "sounds",
                                string.format("%s.PlaybackSpeed -> %.3f", describeInstance(instance), value)
                        )
                        applied = true
                end

                if control.looped ~= nil then
                        if typeof(control.looped) ~= "boolean" then
                                return false, string.format("sounds[%d].looped must be a boolean", index)
                        end
                        instance.Looped = control.looped
                        recordChange(
                                changes,
                                sections,
                                "sounds",
                                string.format("%s.Looped -> %s", describeInstance(instance), tostring(control.looped))
                        )
                        applied = true
                end

                if control.timePosition ~= nil then
                        local value, err = parseNumber(
                                control.timePosition,
                                string.format("sounds[%d].timePosition", index),
                                0,
                                nil
                        )
                        if not value then
                                return false, err
                        end
                        instance.TimePosition = value
                        recordChange(
                                changes,
                                sections,
                                "sounds",
                                string.format("%s.TimePosition -> %.3f", describeInstance(instance), value)
                        )
                        applied = true
                end

                local playFlag = control.play
                local stopFlag = control.stop
                if playFlag and stopFlag then
                        return false, string.format("sounds[%d] cannot request both play and stop", index)
                end

                if playFlag ~= nil and typeof(playFlag) ~= "boolean" then
                        return false, string.format("sounds[%d].play must be a boolean", index)
                end
                if stopFlag ~= nil and typeof(stopFlag) ~= "boolean" then
                        return false, string.format("sounds[%d].stop must be a boolean", index)
                end

                if playFlag then
                        instance:Play()
                        recordChange(
                                changes,
                                sections,
                                "sounds",
                                string.format("%s:Play()", describeInstance(instance))
                        )
                        applied = true
                elseif stopFlag then
                        instance:Stop()
                        recordChange(
                                changes,
                                sections,
                                "sounds",
                                string.format("%s:Stop()", describeInstance(instance))
                        )
                        applied = true
                end

                if applied then
                        sections.sounds = true
                end
        end

        return true, nil
end

local function summariseSections(sections: SectionSet, hadChanges: boolean): string
        if not hadChanges then
                return "No environment changes were applied"
        end

        local labels = {}
        for key in sections do
                local label = SECTION_SUMMARY_LABELS[key] or key
                table.insert(labels, label)
        end

        table.sort(labels)

        if #labels == 0 then
                return "No environment changes were applied"
        end

        if #labels == 1 then
                return string.format("Updated %s settings", labels[1])
        end

        local last = labels[#labels]
        table.remove(labels, #labels)

        if #labels == 1 then
                return string.format("Updated %s and %s settings", labels[1], last)
        end

        return string.format("Updated %s, and %s settings", table.concat(labels, ", "), last)
end

return function(args: ToolArgs): string?
        if args.tool ~= "EnvironmentControl" then
                return nil
        end

        local params = args.params :: EnvironmentControlRequest
        if type(params) ~= "table" then
                local response: EnvironmentControlResponse = {
                        success = false,
                        summary = nil,
                        changes = nil,
                        errors = { "EnvironmentControl requires an object payload" },
                }
                return jsonEncode(response)
        end

        local changes = {}
        local sections: SectionSet = {}
        local errors = {}

        local recording = ChangeHistoryService:TryBeginRecording("EnvironmentControl")
        if recording then
                ChangeHistoryService:SetWaypoint("Before EnvironmentControl")
        end

        local success = true

        local function guardApply(callback)
                if not success then
                        return
                end
                local ok, message = callback()
                if not ok then
                        success = false
                        table.insert(errors, message or "Unknown EnvironmentControl error")
                end
        end

        guardApply(function()
                return applyLighting(params.lighting, changes, sections)
        end)

        guardApply(function()
                return applyAtmosphere(params.atmosphere, changes, sections)
        end)

        guardApply(function()
                return applySky(params.sky, changes, sections)
        end)

        guardApply(function()
                return applyPostProcessingBatch(params.postProcessing, changes, sections)
        end)

        guardApply(function()
                return applyTerrainWater(params.terrainWater, changes, sections)
        end)

        guardApply(function()
                return applySoundService(params.soundService, changes, sections)
        end)

        guardApply(function()
                return applySoundTargets(params.sounds, changes, sections)
        end)

        if recording then
                if success and #changes > 0 then
                        ChangeHistoryService:SetWaypoint("After EnvironmentControl")
                        ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
                else
                        ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
                end
        end

        local response: EnvironmentControlResponse = {
                success = success,
                summary = if success then summariseSections(sections, #changes > 0) else nil,
                changes = if #changes > 0 then changes else nil,
                errors = if #errors > 0 then errors else nil,
        }

        return jsonEncode(response)
end
