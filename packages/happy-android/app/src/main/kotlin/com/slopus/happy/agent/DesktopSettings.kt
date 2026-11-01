package com.slopus.happy.agent

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Happy Desktop's user settings that the phone follows (iOS's
 * `DesktopSettingKeys`). They live on the agent, one per person, so a
 * change on the desktop shows here and one made here shows there.
 */
object DesktopSettings {
    /** Whether the sidebar, and so home, lists the projects: `{"projectsHidden": true}` hides them. */
    const val PROJECTS_VISIBILITY = "happy-desktop.projectsVisibility"

    /** Projects are hidden only by an explicit `true`; unset, cleared or anything else shows them. */
    fun projectsHidden(values: Map<String, JsonElement>): Boolean =
        (values[PROJECTS_VISIBILITY] as? JsonObject)?.get("projectsHidden") == JsonPrimitive(true)

    /** The value that hides ([hidden]) or shows the projects, as the desktop writes it. */
    fun projectsVisibility(hidden: Boolean): JsonObject = buildJsonObject { put("projectsHidden", hidden) }
}
