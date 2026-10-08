/**
The Nerd Font icons the toolkit draws (design-system `GLY4`), by name.

$(B Generated) by `apps/ci/tools/gen-icons.d` from Nerd Fonts 3.4.0's
`glyphnames.json`; do not edit. An icon joins the curated list in the
generator when a component draws it. A Nerd Font is baseline on GUI and Web
and the configured `nerdFont` capability on a terminal, so a component draws
these through the glyph ladder, which substitutes where the target has none.
*/
module sparkles.ui.icons;

/// The Nerd Fonts release the table was generated from.
enum string nerdFontsVersion = "3.4.0";

/// One code point per icon; each member's comment is its `glyphnames.json` name.
enum Icon : dchar
{
    faCheck = '\U0000F00C', /// `fa-check`
    faXmark = '\U0000F00D', /// `fa-xmark`
    faTriangleExclamation = '\U0000F071', /// `fa-triangle_exclamation`
    faCircleInfo = '\U0000F05A', /// `fa-circle_info`
    faCircleO = '\U0000F10C', /// `fa-circle_o`
    faSpinner = '\U0000F110', /// `fa-spinner`
    faMinus = '\U0000F068', /// `fa-minus`
    mdInformationOutline = '\U000F02FD', /// `md-information_outline`
    mdLightbulbOutline = '\U000F0336', /// `md-lightbulb_outline`
    mdCommentAlertOutline = '\U000F017E', /// `md-comment_alert_outline`
    mdAlertOutline = '\U000F002A', /// `md-alert_outline`
    mdAlertOctagonOutline = '\U000F0CE6', /// `md-alert_octagon_outline`
    mdCheckboxOutline = '\U000F0C52', /// `md-checkbox_outline`
    mdCheckboxBlankOutline = '\U000F0131', /// `md-checkbox_blank_outline`
    mdImageOutline = '\U000F0976', /// `md-image_outline`
    mdVectorSquare = '\U000F0001', /// `md-vector_square`
    mdNumeric1CircleOutline = '\U000F0CA1', /// `md-numeric_1_circle_outline`
    mdNumeric2CircleOutline = '\U000F0CA3', /// `md-numeric_2_circle_outline`
    mdNumeric3CircleOutline = '\U000F0CA5', /// `md-numeric_3_circle_outline`
    mdNumeric4CircleOutline = '\U000F0CA7', /// `md-numeric_4_circle_outline`
    mdNumeric5CircleOutline = '\U000F0CA9', /// `md-numeric_5_circle_outline`
    mdNumeric6CircleOutline = '\U000F0CAB', /// `md-numeric_6_circle_outline`
    devTerminal = '\U0000E795', /// `dev-terminal`
    devDlang = '\U0000E7AF', /// `dev-dlang`
    mdNix = '\U000F1105', /// `md-nix`
    mdSsh = '\U000F08C0', /// `md-ssh`
    mdMonitor = '\U000F0379', /// `md-monitor`
    mdWeb = '\U000F059F', /// `md-web`
    mdEmail = '\U000F01EE', /// `md-email`
}

/// The `glyphnames.json` name of each $(LREF Icon) member, in declaration order.
static immutable string[] iconSourceNames = [
    `fa-check`,
    `fa-xmark`,
    `fa-triangle_exclamation`,
    `fa-circle_info`,
    `fa-circle_o`,
    `fa-spinner`,
    `fa-minus`,
    `md-information_outline`,
    `md-lightbulb_outline`,
    `md-comment_alert_outline`,
    `md-alert_outline`,
    `md-alert_octagon_outline`,
    `md-checkbox_outline`,
    `md-checkbox_blank_outline`,
    `md-image_outline`,
    `md-vector_square`,
    `md-numeric_1_circle_outline`,
    `md-numeric_2_circle_outline`,
    `md-numeric_3_circle_outline`,
    `md-numeric_4_circle_outline`,
    `md-numeric_5_circle_outline`,
    `md-numeric_6_circle_outline`,
    `dev-terminal`,
    `dev-dlang`,
    `md-nix`,
    `md-ssh`,
    `md-monitor`,
    `md-web`,
    `md-email`,
];
