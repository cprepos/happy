package com.slopus.happy.ui.chat

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.slopus.happy.R
import com.slopus.happy.conversation.NewWork
import com.slopus.happy.conversation.WorkChoice
import com.slopus.happy.conversation.WorkKind
import com.slopus.happy.ui.components.Icon
import com.slopus.happy.ui.components.Ionicon
import com.slopus.happy.ui.components.rememberReduceMotion
import com.slopus.happy.ui.home.BotFaceSpec
import com.slopus.happy.ui.theme.HappyTheme
import com.slopus.happy.ui.theme.happyTextStyle

object NewWorkTags {
    const val PANEL = "newWork"
    const val KIND = "newWork.kind"
    fun kind(kind: WorkKind) = "newWork.kind.${kind.name}"
    const val NAME = "newWork.name"
    /** The name's capsule. */
    const val NAME_FIELD = "newWork.nameField"
    const val NOTE = "newWork.note"
    const val MACHINE = "newWork.machine"
    const val FOLDER = "newWork.folder"
}

/** happy-ios NewWorkLayout's metrics and NewWorkPanel's type. */
object NewWorkSpec {
    val side = 24.dp
    val maxWidth = 320.dp
    val kindWidth = 220.dp
    val kindToRows = 16.dp
    val rowHeight = 44.dp
    val rowGap = 8.dp
    val rowsToNote = 10.dp
    /** The least room kept over and under the block; with less it doesn't show. */
    val margin = 12.dp
    /** The name's and the rows' text, in from the capsule's ends. */
    val rowInset = 16.dp
    val rowIcon = 16.dp
    val rowIconGap = 8.dp
    const val FADE_MILLIS = 200
    val field = happyTextStyle(fontSize = 16)
    val note = happyTextStyle(fontSize = 13, lineHeight = 18)

    /** The block's width in a room [width] wide: 24 in from either side, at most 320. */
    fun blockWidth(width: Dp): Dp = minOf(maxWidth, width - side * 2).coerceAtLeast(0.dp)
}

/**
 * New work's block, centred in the room between the bar and the composer
 * that this fills (happy-ios NewWorkLayout): [NewWorkSpec.blockWidth] wide,
 * shown only with at least 12 left over and under it. The composer rides the
 * keyboard and the room ends at it, so the block moves with it, in the same
 * frame. Going ([shown] false) it fades out over 0.2 s, ease-out, and is gone.
 */
@Composable
fun NewWorkRoom(shown: Boolean, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val reduceMotion = rememberReduceMotion()
    val alpha by animateFloatAsState(
        if (shown) 1f else 0f,
        if (reduceMotion) snap() else tween(NewWorkSpec.FADE_MILLIS, easing = FastOutSlowInEasing),
        label = "new work",
    )
    if (!shown && alpha == 0f) return
    Layout(content, modifier.fillMaxSize()) { measurables, constraints ->
        val width = constraints.maxWidth
        val height = constraints.maxHeight
        val blockWidth = NewWorkSpec.blockWidth(width.toDp()).roundToPx()
        val block = measurables.single().measure(Constraints(minWidth = blockWidth, maxWidth = blockWidth))
        val fits = height >= block.height + 2 * NewWorkSpec.margin.roundToPx()
        layout(width, height) {
            if (fits) block.placeWithLayer((width - blockWidth) / 2, (height - block.height) / 2) { this.alpha = alpha }
        }
    }
}

/**
 * Happy Agent's new work (happy-ios NewWorkPanel `.work`): Task or Bot, a
 * segmented control 220 wide (Home's Session | Bot look: 32 high, 2 in,
 * radius 9; the picked segment surfaceHighest, radius 7; 13 semibold), 16
 * over the name, a 44 capsule on the input ground with its 16 text centred,
 * "Name (optional)" until typed; 10 under it a line saying what the kind is
 * (13/18 secondary, centred, wrapping). Every change goes to [onChange] as
 * it is made, a kind change with a tick. Return in the name goes on to the
 * composer ([onReturn]). Fixed while the work is being made.
 */
@Composable
fun NewWorkChoicePanel(work: NewWork, onChange: (WorkChoice) -> Unit, onReturn: () -> Unit) {
    val colors = HappyTheme.colors
    val haptics = LocalHapticFeedback.current
    val enabled = !work.making
    // Typed here and handed on, so the field never waits on the chat to echo it.
    var name by rememberSaveable { mutableStateOf(work.choice.name) }
    Column(Modifier.fillMaxWidth().testTag(NewWorkTags.PANEL), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(
            modifier = Modifier
                .testTag(NewWorkTags.KIND)
                .width(NewWorkSpec.kindWidth)
                .heightIn(min = BotFaceSpec.segmentHeight)
                .clip(RoundedCornerShape(BotFaceSpec.segmentRadius))
                .background(colors.glass.backgroundSubtle)
                .padding(BotFaceSpec.segmentPadding),
        ) {
            listOf(WorkKind.Task to R.string.new_work_task, WorkKind.Bot to R.string.new_work_bot).forEach { (kind, label) ->
                val selected = kind == work.choice.kind
                Box(
                    modifier = Modifier
                        .testTag(NewWorkTags.kind(kind))
                        .weight(1f)
                        .heightIn(min = BotFaceSpec.segmentHeight - BotFaceSpec.segmentPadding * 2)
                        .clip(RoundedCornerShape(BotFaceSpec.segmentItemRadius))
                        .background(if (selected) colors.surfaceHighest else Color.Transparent)
                        .clickable(enabled = enabled, role = Role.RadioButton) {
                            if (!selected) {
                                haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                                onChange(WorkChoice(kind, name))
                            }
                        }
                        .semantics { this.selected = selected },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        stringResource(label),
                        style = BotFaceSpec.segmentLabel,
                        color = if (selected) colors.text else colors.textSecondary,
                        maxLines = 1,
                    )
                }
            }
        }
        Spacer(Modifier.height(NewWorkSpec.kindToRows))
        val placeholder = stringResource(R.string.new_work_name)
        // The capsule holds the field, whose own node is only its line.
        Box(
            modifier = Modifier
                .testTag(NewWorkTags.NAME_FIELD)
                .fillMaxWidth()
                .heightIn(min = NewWorkSpec.rowHeight)
                .clip(CircleShape)
                .background(colors.input.background)
                .padding(horizontal = NewWorkSpec.rowInset),
            contentAlignment = Alignment.Center,
        ) {
            BasicTextField(
                value = name,
                onValueChange = {
                    name = it
                    onChange(WorkChoice(work.choice.kind, it))
                },
                enabled = enabled,
                singleLine = true,
                textStyle = NewWorkSpec.field.copy(color = colors.input.text, textAlign = TextAlign.Center),
                cursorBrush = SolidColor(colors.input.text),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Next),
                keyboardActions = KeyboardActions(onNext = { onReturn() }),
                decorationBox = { inner ->
                    Box(contentAlignment = Alignment.Center) {
                        if (name.isEmpty()) {
                            Text(placeholder, style = NewWorkSpec.field, color = colors.input.placeholder, textAlign = TextAlign.Center, maxLines = 1)
                        }
                        inner()
                    }
                },
                modifier = Modifier.fillMaxWidth().testTag(NewWorkTags.NAME),
            )
        }
        Spacer(Modifier.height(NewWorkSpec.rowsToNote))
        Text(
            stringResource(if (work.choice.kind == WorkKind.Bot) R.string.new_work_bot_note else R.string.new_work_task_note),
            style = NewWorkSpec.note,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().testTag(NewWorkTags.NOTE),
        )
    }
}

/**
 * One of a Happy account's rows (happy-ios NewWorkMenuRow): a 44 capsule on
 * the input ground, 16 in, a 16 glyph 8 before what is chosen (16, the
 * middle truncated), opening [menu] under it. Dimmed while fixed.
 */
@Composable
fun NewWorkMenuRow(
    icon: Ionicon,
    title: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    menu: @Composable () -> Unit = {},
) {
    val colors = HappyTheme.colors
    Box(modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = NewWorkSpec.rowHeight)
                .clip(CircleShape)
                .background(colors.input.background)
                .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
                .alpha(if (enabled) 1f else 0.5f)
                .padding(horizontal = NewWorkSpec.rowInset),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(NewWorkSpec.rowIconGap, Alignment.CenterHorizontally),
        ) {
            Icon(icon, NewWorkSpec.rowIcon, colors.input.text)
            Text(title, style = NewWorkSpec.field, color = colors.input.text, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
        }
        menu()
    }
}
