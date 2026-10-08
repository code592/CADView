use cad_core::TextGeometry2D;
use cad_core::{TextRun2D, TextStyle2D};
use std::collections::BTreeSet;

pub(crate) struct SourceMTextColumns<'a> {
    pub kind: i16,
    pub count: i32,
    pub width: f64,
    pub gutter: f64,
    pub defined_height: f64,
    pub total_width: f64,
    pub heights: &'a [f64],
    pub flow_reversed: bool,
    pub auto_height: bool,
}

pub(crate) fn mtext_columns(
    source: SourceMTextColumns<'_>,
    breaks: &[u32],
    warnings: &mut Vec<String>,
) -> Option<cad_core::MTextColumns2D> {
    if source.kind == 0 {
        return None;
    }
    let invalid = |warnings: &mut Vec<String>| {
        warnings.push("mtext_column_parameters_invalid".to_owned());
        None
    };
    if !matches!(source.kind, 1 | 2)
        || !source.width.is_finite()
        || source.width <= 0.0
        || !source.gutter.is_finite()
        || source.gutter < 0.0
    {
        return invalid(warnings);
    }
    let count = if source.kind == 2 && source.auto_height && source.count == 0 {
        let derived = (source.total_width + source.gutter) / (source.width + source.gutter);
        if !derived.is_finite()
            || (derived - derived.round()).abs() > 1e-6
            || !(1.0..=4096.0).contains(&derived.round())
        {
            return invalid(warnings);
        }
        derived.round() as i32
    } else {
        source.count
    };
    if !(1..=4096).contains(&count)
        || !(source.width * f64::from(count) + source.gutter * f64::from(count - 1)).is_finite()
    {
        return invalid(warnings);
    }
    let manual_heights = source.kind == 2 && !source.auto_height;
    if manual_heights {
        if source.heights.len() != count as usize
            || source.heights.iter().enumerate().any(|(index, height)| {
                !height.is_finite()
                    || *height < 0.0
                    || (*height == 0.0 && index + 1 != count as usize)
            })
        {
            return invalid(warnings);
        }
    } else if !source.defined_height.is_finite() || source.defined_height <= 0.0 {
        return invalid(warnings);
    }
    if breaks.len() >= count as usize {
        // Remaining controls stay decoded as line breaks in the last column;
        // bound segmentation work without discarding any readable content.
        warnings.push("mtext_excess_column_breaks".to_owned());
    }
    Some(cad_core::MTextColumns2D {
        count: count as u32,
        width: source.width,
        gutter: source.gutter,
        defined_height: if manual_heights {
            0.0
        } else {
            source.defined_height
        },
        heights: if manual_heights {
            source.heights.to_vec()
        } else {
            Vec::new()
        },
        flow_reversed: source.flow_reversed,
        auto_height: source.auto_height,
        manual_breaks: breaks.iter().copied().take(count as usize - 1).collect(),
    })
}

pub(crate) fn mtext_background(
    flags: i32,
    scale: f64,
    color_mode: cad_core::MTextBackgroundColor2D,
    color_argb: u32,
    transparency: u32,
    warnings: &mut Vec<String>,
) -> Option<cad_core::MTextBackground2D> {
    if flags & !0x13 != 0 {
        warnings.push("mtext_background_unknown_flags".to_owned());
    }
    if flags & 0x13 == 0 {
        return None;
    }
    let scale = if scale.is_finite() && (1.0..=5.0).contains(&scale) {
        scale
    } else {
        warnings.push("mtext_background_scale_fallback".to_owned());
        1.5
    };
    if transparency != 0 {
        // Autodesk defines the background mask as opaque; DXF group 441 is
        // explicitly documented as not implemented. Retain the source value
        // for diagnostics rather than inventing different compositing.
        warnings.push("mtext_background_transparency_not_applied".to_owned());
    }
    Some(cad_core::MTextBackground2D {
        layout_supported: true,
        fill: flags & 3 != 0,
        frame: flags & 0x10 != 0,
        scale,
        color_mode: if flags & 2 != 0 {
            cad_core::MTextBackgroundColor2D::Canvas
        } else {
            color_mode
        },
        color_argb,
        transparency,
    })
}

pub(crate) fn mtext_line_spacing(
    factor: f64,
    exact: bool,
    warnings: &mut Vec<String>,
) -> cad_core::MTextLineSpacing2D {
    let factor = if factor.is_finite() && (0.25..=4.0).contains(&factor) {
        factor
    } else {
        warnings.push("line_spacing_factor_fallback".to_owned());
        1.0
    };
    cad_core::MTextLineSpacing2D {
        factor,
        style: if exact {
            cad_core::MTextLineSpacingStyle2D::Exact
        } else {
            cad_core::MTextLineSpacingStyle2D::AtLeast
        },
    }
}

pub(crate) fn append_text_diagnostics(
    scene: &cad_core::Scene2D,
    diagnostics: &mut Vec<cad_core::FormatDiagnostic>,
) {
    let mut counts = std::collections::BTreeMap::<&str, usize>::new();
    for entity in &scene.entities {
        if let cad_core::Entity2DGeometry::Text(text_geometry) = &entity.geometry {
            let TextGeometry2D { text_warnings, .. } = &**text_geometry;
            for warning in text_warnings {
                *counts.entry(warning).or_default() += 1;
            }
        }
    }
    for (code, count) in counts {
        diagnostics.push(cad_core::FormatDiagnostic {
            code: format!("cad.text.{code}"),
            message: format!("{count} text entities use a readable fallback for {code}; this formatting is not CAD-exact"),
            severity: cad_core::DiagnosticSeverity::Warning,
            entity_id: None,
        });
    }
}

pub(crate) struct ParsedCadText {
    pub value: String,
    pub runs: Vec<TextRun2D>,
    pub warnings: Vec<String>,
    pub column_breaks: Vec<u32>,
}

/// First private-use code point of the bundled "CADView CAD Symbols" font.
pub(crate) const CAD_REBAR_SYMBOL_BASE: u32 = 0xE130;

/// Chinese structural SHX fonts (tssdeng.shx and compatible) draw codes
/// 130–133 (`%%130`–`%%133`) as rebar grade symbols: HPB300, HRB335, HRB400
/// and RRB400. As raw C1 controls they would render as missing-glyph boxes,
/// so map them to the bundled symbol glyphs.
fn cad_special_symbol(character: char) -> char {
    match character as u32 {
        code @ 0x82..=0x85 => {
            char::from_u32(CAD_REBAR_SYMBOL_BASE + (code - 0x82)).unwrap_or(character)
        }
        _ => character,
    }
}

/// Some SHX fonts draw ASCII characters as engineering symbols. These maps
/// are limited to fonts confirmed against an AutoCAD plot: ebgen.shx draws
/// `^` as the HPB300 rebar symbol and `*` as a multiplication sign.
pub(crate) fn apply_shx_symbol_maps(entities: &mut [cad_core::Entity2D]) {
    for entity in entities {
        if let cad_core::Entity2DGeometry::Text(text) = &mut entity.geometry {
            let TextGeometry2D {
                value,
                shx: Some(shx),
                ..
            } = &mut **text
            else {
                continue;
            };
            if shx.font.as_deref() == Some("ebgen.shx") && value.contains(['^', '*']) {
                // All are one UTF-16 unit, so style-run offsets stay valid.
                *value = value.replace('^', "\u{e130}").replace('*', "×");
            }
        }
    }
}

pub(crate) fn parse_mtext(value: &str, base_height: f64) -> ParsedCadText {
    parse_text(value, true, base_height)
}

pub(crate) fn parse_single_line_text(value: &str) -> ParsedCadText {
    parse_text(value, false, 1.0)
}

#[cfg(test)]
fn normalize_cad_text(value: &str) -> String {
    parse_mtext(value, 1.0).value
}

/// TEXT and single-line attributes do not use MTEXT's paragraph, font or
/// grouping syntax. Never strip literal paths/braces from those labels.
#[cfg(test)]
fn normalize_single_line_text(value: &str) -> String {
    parse_single_line_text(value).value
}

struct TextBuilder {
    value: String,
    runs: Vec<TextRun2D>,
    style: TextStyle2D,
    cursor: u32,
    warnings: BTreeSet<String>,
    run_limit: bool,
    column_breaks: Vec<u32>,
}

impl TextBuilder {
    fn push(&mut self, value: char) {
        self.push_str(value.encode_utf8(&mut [0; 4]));
    }
    fn push_str(&mut self, value: &str) {
        if value.is_empty() {
            return;
        }
        let start = self.cursor;
        self.cursor = self
            .cursor
            .saturating_add(value.encode_utf16().count() as u32);
        self.value.push_str(value);
        if self.run_limit {
            return;
        }
        if let Some(last) = self.runs.last_mut().filter(|run| run.style == self.style) {
            last.end = self.cursor;
        } else if self.runs.len() < 4096 {
            self.runs.push(TextRun2D {
                start,
                end: self.cursor,
                style: self.style.clone(),
            });
        } else {
            self.run_limit = true;
            self.warnings.insert("rich_text_run_limit".to_owned());
        }
    }
    fn warning(&mut self, code: &str) {
        self.warnings.insert(code.to_owned());
    }
    fn finish(mut self) -> ParsedCadText {
        if self.run_limit
            || self
                .runs
                .iter()
                .all(|run| run.style == TextStyle2D::default())
        {
            self.runs.clear();
        }
        ParsedCadText {
            // One UTF-16 unit each way, so style-run offsets stay valid.
            value: self.value.chars().map(cad_special_symbol).collect(),
            runs: self.runs,
            warnings: self.warnings.into_iter().collect(),
            column_breaks: self.column_breaks,
        }
    }
}

fn parse_text(value: &str, is_mtext: bool, base_height: f64) -> ParsedCadText {
    let mut output = TextBuilder {
        value: String::with_capacity(value.len()),
        runs: Vec::new(),
        style: TextStyle2D::default(),
        cursor: 0,
        warnings: BTreeSet::new(),
        run_limit: false,
        column_breaks: Vec::new(),
    };
    let base_height = if base_height.is_finite() && base_height > 0.0 {
        base_height
    } else {
        1.0
    };
    let mut scopes = Vec::new();
    let mut overflow_depth = 0_usize;
    let mut chars = value.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '%' && chars.peek() == Some(&'%') {
            chars.next();
            let code = chars.next();
            match code.map(|value| value.to_ascii_lowercase()) {
                Some('d') => output.push('°'),
                Some('p') => output.push('±'),
                Some('c') => output.push('⌀'),
                Some('%') => output.push('%'),
                Some(toggle @ ('u' | 'o' | 'k')) if !is_mtext => {
                    let enabled = match toggle {
                        'u' => &mut output.style.underline,
                        'o' => &mut output.style.overline,
                        _ => &mut output.style.strike_through,
                    };
                    *enabled = !*enabled;
                }
                Some(first) if first.is_ascii_digit() => {
                    let mut digits = String::from(first);
                    for _ in 0..2 {
                        if chars.peek().is_some_and(char::is_ascii_digit) {
                            digits.push(chars.next().unwrap());
                        }
                    }
                    if digits.len() != 3 {
                        output.push_str("%%");
                        output.push_str(&digits);
                    } else if let Ok(codepoint) = digits.parse::<u32>() {
                        if let Some(decoded) = char::from_u32(codepoint) {
                            output.push(decoded);
                        }
                    }
                }
                Some(_) => {
                    output.push('%');
                    output.push('%');
                    output.push(code.unwrap());
                }
                None => output.push_str("%%"),
            }
            continue;
        }
        if character != '\\' {
            if is_mtext && character == '{' {
                if scopes.len() < 64 && overflow_depth == 0 {
                    scopes.push(output.style.clone());
                } else {
                    overflow_depth = overflow_depth.saturating_add(1);
                    output.warning("rich_text_group_limit");
                }
            } else if is_mtext && character == '}' {
                if overflow_depth > 0 {
                    overflow_depth -= 1;
                } else if let Some(style) = scopes.pop() {
                    output.style = style;
                }
            } else {
                output.push(character);
            }
            continue;
        }
        let Some(command) = chars.next() else {
            output.push('\\');
            break;
        };
        if !is_mtext && !(matches!(command, 'U' | 'u') && chars.peek() == Some(&'+')) {
            output.push('\\');
            output.push(command);
            continue;
        }
        match command {
            'P' | 'X' => output.push('\n'),
            'N' => {
                output.column_breaks.push(output.cursor);
                output.push('\n');
            }
            // Lowercase \p introduces paragraph formatting and terminates at
            // a semicolon; it is not a line break.
            'p' => {
                consume_until_semicolon(&mut chars);
                output.warning("paragraph_format_fallback");
            }
            '~' => output.push('\u{a0}'),
            '\\' | '{' | '}' => output.push(command),
            'U' | 'u' if chars.peek() == Some(&'+') => {
                chars.next();
                let mut digits = String::new();
                while digits.len() < 4 && chars.peek().is_some_and(char::is_ascii_hexdigit) {
                    digits.push(chars.next().unwrap());
                }
                let codepoint =
                    (digits.len() == 4).then(|| u32::from_str_radix(&digits, 16).unwrap());
                if let Some(codepoint) = codepoint {
                    if (0xd800..=0xdbff).contains(&codepoint) {
                        // CAD encodes supplementary characters as two UTF-16
                        // escapes. Decode them together instead of dropping
                        // both surrogate halves as invalid scalar values.
                        let mut next = chars.clone();
                        if next.next() == Some('\\')
                            && matches!(next.next(), Some('U' | 'u'))
                            && next.next() == Some('+')
                        {
                            let low_digits = next.by_ref().take(4).collect::<String>();
                            if let Ok(low) = u32::from_str_radix(&low_digits, 16) {
                                if low_digits.len() == 4 && (0xdc00..=0xdfff).contains(&low) {
                                    let scalar =
                                        0x10000 + ((codepoint - 0xd800) << 10) + low - 0xdc00;
                                    output.push(char::from_u32(scalar).unwrap());
                                    chars = next;
                                    continue;
                                }
                            }
                        }
                    } else if let Some(decoded) = char::from_u32(codepoint) {
                        output.push(decoded);
                        continue;
                    }
                }
                // Invalid/truncated escapes remain readable and never consume
                // the following label or formatting command.
                output.push('\\');
                output.push(command);
                output.push('+');
                output.push_str(&digits);
            }
            // Stacked fractions/tolerances. Showing readable linear text is
            // preferable to dropping the entire value when the CAD font or
            // rich-text layout is unavailable.
            'S' => {
                let stacked = take_until_semicolon(&mut chars);
                output.push_str(&stacked.replace(['^', '#'], "/"));
                output.warning("stacked_text_fallback");
            }
            // Toggle-only MTEXT controls.
            'L' | 'l' => output.style.underline = command == 'L',
            'O' | 'o' => output.style.overline = command == 'O',
            'K' | 'k' => output.style.strike_through = command == 'K',
            'F' | 'f' => {
                let payload = take_until_semicolon(&mut chars);
                let mut parts = payload.split('|');
                let family = parts.next().unwrap_or_default().trim();
                // Inline font names are family names, not file access requests.
                let name = family.replace('\\', "/");
                let name = name.rsplit('/').next().unwrap_or_default();
                output.style.font_family = if name.len() > 256 {
                    output.warning("font_name_limit");
                    None
                } else if name.to_ascii_lowercase().ends_with(".shx") {
                    output.warning("shx_font_substitution");
                    None
                } else {
                    let name = name
                        .rsplit_once('.')
                        .filter(|(_, extension)| {
                            extension.eq_ignore_ascii_case("ttf")
                                || extension.eq_ignore_ascii_case("otf")
                        })
                        .map_or(name, |(stem, _)| stem);
                    (!name.is_empty()).then(|| name.to_owned())
                };
                output.style.bold = false;
                output.style.italic = false;
                for part in parts {
                    if part.starts_with('b') {
                        output.style.bold = part == "b1";
                    } else if part.starts_with('i') {
                        output.style.italic = part == "i1";
                    }
                }
            }
            'H' => {
                let mut number = String::new();
                while chars
                    .peek()
                    .is_some_and(|c| c.is_ascii_digit() || matches!(c, '+' | '-' | '.' | 'e' | 'E'))
                {
                    number.push(chars.next().unwrap());
                }
                let relative = chars.peek() == Some(&'x');
                if relative {
                    chars.next();
                }
                if chars.peek() == Some(&';') {
                    chars.next();
                }
                match number.parse::<f64>() {
                    Ok(height) if height.is_finite() && height > 0.0 => {
                        let factor = if relative {
                            output.style.height_factor * height
                        } else {
                            height / base_height
                        };
                        if factor.is_finite() && (1e-4..=1024.0).contains(&factor) {
                            output.style.height_factor = factor;
                        } else {
                            output.warning("rich_text_height_limit");
                        }
                    }
                    Ok(_) => output.warning("invalid_text_height"),
                    Err(_) => {
                        output.push('\\');
                        output.push(command);
                        output.push_str(&number);
                        if relative {
                            output.push('x');
                        }
                        output.warning("invalid_text_height");
                    }
                }
            }
            // Formatting commands whose payload ends at a semicolon.
            'A' | 'C' | 'c' | 'Q' | 'T' | 'W' => {
                consume_until_semicolon(&mut chars);
                output.warning("inline_format_fallback");
            }
            _ => {
                // Preserve unknown escapes instead of discarding all text up
                // to the next semicolon. This keeps vendor-specific content
                // readable with a fallback font.
                output.push('\\');
                output.push(command);
            }
        }
    }
    output.finish()
}

fn consume_until_semicolon<I>(chars: &mut std::iter::Peekable<I>)
where
    I: Iterator<Item = char>,
{
    let _ = take_until_semicolon(chars);
}

fn take_until_semicolon<I>(chars: &mut std::iter::Peekable<I>) -> String
where
    I: Iterator<Item = char>,
{
    let mut value = String::new();
    for next in chars.by_ref() {
        if next == ';' {
            break;
        }
        value.push(next);
    }
    value
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column_source() -> SourceMTextColumns<'static> {
        SourceMTextColumns {
            kind: 2,
            count: 0,
            width: 50.0,
            gutter: 12.5,
            defined_height: 150.0,
            total_width: 175.0,
            heights: &[],
            flow_reversed: true,
            auto_height: true,
        }
    }

    #[test]
    fn automatic_column_count_uses_total_width_without_changing_glyph_height() {
        let mut warnings = Vec::new();
        let columns = mtext_columns(column_source(), &[], &mut warnings).unwrap();
        assert_eq!(columns.count, 3);
        assert_eq!(columns.defined_height, 150.0);
        assert_eq!(columns.width, 50.0);
        assert!(columns.flow_reversed && columns.auto_height);
        assert!(warnings.is_empty());
        for total in [0.0, 176.0, f64::NAN, f64::INFINITY, 1e300] {
            let source = SourceMTextColumns {
                total_width: total,
                ..column_source()
            };
            assert!(mtext_columns(source, &[], &mut warnings).is_none());
        }
        assert!(warnings
            .iter()
            .all(|w| w == "mtext_column_parameters_invalid"));
    }

    #[test]
    fn column_resources_and_manual_height_sentinel_are_validated() {
        let mut warnings = Vec::new();
        let source = || SourceMTextColumns {
            count: 3,
            auto_height: false,
            heights: &[160.0, 140.0, 0.0],
            ..column_source()
        };
        let columns = mtext_columns(source(), &[3, 7, 11, 15], &mut warnings).unwrap();
        assert_eq!(columns.defined_height, 0.0);
        assert_eq!(columns.heights, [160.0, 140.0, 0.0]);
        assert_eq!(columns.manual_breaks, [3, 7]);
        assert_eq!(warnings, ["mtext_excess_column_breaks"]);
        for heights in [
            &[0.0, 140.0, 0.0][..],
            &[160.0, -1.0, 0.0],
            &[160.0, f64::INFINITY, 0.0],
            &[160.0, 140.0],
        ] {
            assert!(mtext_columns(
                SourceMTextColumns {
                    heights,
                    ..source()
                },
                &[],
                &mut warnings
            )
            .is_none());
        }
        for count in [-1, 0, 4097, i32::MAX] {
            assert!(
                mtext_columns(SourceMTextColumns { count, ..source() }, &[], &mut warnings)
                    .is_none()
            );
        }
    }

    #[test]
    fn manual_column_breaks_keep_decoded_utf16_and_scoped_runs_aligned() {
        let parsed = parse_mtext(r"{\H2x;日本語😀}\Nالعربية\Pবাংলা\Nไทย", 10.0);
        assert_eq!(parsed.value, "日本語😀\nالعربية\nবাংলা\nไทย");
        assert_eq!(parsed.column_breaks, [5, 19]);
        assert_eq!(parsed.runs[0].start, 0);
        assert_eq!(parsed.runs[0].end, 5);
        assert_eq!(parsed.runs[0].style.height_factor, 2.0);
    }

    #[test]
    fn background_validation_preserves_flags_and_bounds_bad_margins() {
        use cad_core::MTextBackgroundColor2D as C;
        let mut warnings = Vec::new();
        assert!(mtext_background(0, f64::NAN, C::Explicit, 0, 0, &mut warnings).is_none());
        assert!(warnings.is_empty());
        for scale in [f64::NAN, f64::INFINITY, -1.0, 0.0, 5.1] {
            warnings.clear();
            let background = mtext_background(
                19,
                scale,
                C::Explicit,
                0xff123456,
                0x02000080,
                &mut warnings,
            )
            .unwrap();
            assert!(background.fill && background.frame);
            assert_eq!(background.scale, 1.5);
            assert_eq!(background.color_mode, C::Canvas);
            assert_eq!(background.transparency, 0x02000080);
            assert_eq!(warnings.len(), 2);
        }
        let frame = mtext_background(16, 5.0, C::Explicit, 0, 0, &mut Vec::new()).unwrap();
        assert!(!frame.fill && frame.frame);
        assert_eq!(frame.scale, 5.0);
    }

    #[test]
    fn mtext_spacing_preserves_valid_values_and_diagnoses_invalid_factors() {
        for factor in [0.25, 0.6, 1.0, 4.0] {
            for exact in [false, true] {
                let mut warnings = Vec::new();
                let spacing = mtext_line_spacing(factor, exact, &mut warnings);
                assert_eq!(spacing.factor, factor);
                assert_eq!(
                    spacing.style == cad_core::MTextLineSpacingStyle2D::Exact,
                    exact
                );
                assert!(warnings.is_empty());
            }
        }
        for factor in [f64::NAN, f64::INFINITY, -1.0, 0.0, 4.1] {
            let mut warnings = Vec::new();
            assert_eq!(mtext_line_spacing(factor, false, &mut warnings).factor, 1.0);
            assert_eq!(warnings, ["line_spacing_factor_fallback"]);
        }
    }

    #[test]
    fn scoped_fonts_heights_and_decorations_keep_utf16_ranges() {
        let text = parse_mtext(
            r"中文{\fCADView Noto CJK|i1|b1;\H2x;\LAB\l\U+D83D\U+DE00}\PC",
            10.0,
        );
        assert_eq!(text.value, "中文AB😀\nC");
        assert!(text.warnings.is_empty());
        assert_eq!(
            text.runs
                .iter()
                .map(|run| (run.start, run.end))
                .collect::<Vec<_>>(),
            vec![(0, 2), (2, 4), (4, 6), (6, 8)]
        );
        assert_eq!(text.runs[0].style, TextStyle2D::default());
        assert_eq!(
            text.runs[1].style.font_family.as_deref(),
            Some("CADView Noto CJK")
        );
        assert!(
            text.runs[1].style.bold && text.runs[1].style.italic && text.runs[1].style.underline
        );
        assert_eq!(text.runs[1].style.height_factor, 2.0);
        assert!(!text.runs[2].style.underline);
        assert_eq!(text.runs[3].style, TextStyle2D::default());
    }

    #[test]
    fn nested_height_scopes_accumulate_and_absolute_height_uses_base_units() {
        let text = parse_mtext(r"\H2x;A{\H2x;B{\H5;C}D}E", 10.0);
        assert_eq!(text.value, "ABCDE");
        assert_eq!(
            text.runs
                .iter()
                .map(|run| run.style.height_factor)
                .collect::<Vec<_>>(),
            vec![2.0, 4.0, 0.5, 4.0, 2.0]
        );
        let text = parse_mtext(r"\H2x中文\H.5x;日本語\H+1e1;한국어", 5.0);
        assert_eq!(text.value, "中文日本語한국어");
        assert_eq!(
            text.runs
                .iter()
                .map(|run| run.style.height_factor)
                .collect::<Vec<_>>(),
            vec![2.0, 1.0, 2.0]
        );
    }

    #[test]
    fn single_line_percent_decoration_toggles_do_not_print_as_codes() {
        let text = parse_single_line_text("A%%u中文%%o e\u{301}%%uB%%kC%%oD%%kE");
        assert_eq!(text.value, "A中文 e\u{301}BCDE");
        assert!(text.runs[1].style.underline);
        assert!(text.runs[2].style.underline && text.runs[2].style.overline);
        assert!(!text.runs[3].style.underline && text.runs[3].style.overline);
        assert!(text.runs[4].style.overline && text.runs[4].style.strike_through);
        assert!(text.runs[5].style.strike_through && !text.runs[5].style.overline);
        assert_eq!(text.runs[6].style, TextStyle2D::default());
    }

    #[test]
    fn rich_text_resources_are_bounded_without_discarding_the_label() {
        let text = parse_mtext(&("{".repeat(10000) + "中文" + &"}".repeat(10000)), 10.0);
        assert_eq!(text.value, "中文");
        assert!(text.warnings.contains(&"rich_text_group_limit".to_owned()));
        let text = parse_mtext(&r"\LA\lB".repeat(5000), 10.0);
        assert_eq!(text.value, "AB".repeat(5000));
        assert!(text.runs.is_empty());
        assert!(text.warnings.contains(&"rich_text_run_limit".to_owned()));
        let text = parse_mtext(r"\H1e99;中文\H-1;日本語\H1..5;한국어", 10.0);
        assert_eq!(text.value, r"中文日本語\H1..5한국어");
        assert!(text.runs.is_empty());
        assert!(text.warnings.contains(&"rich_text_height_limit".to_owned()));
        assert!(text.warnings.contains(&"invalid_text_height".to_owned()));
    }

    #[test]
    fn removes_mtext_controls_but_keeps_symbols_and_unicode() {
        assert_eq!(normalize_cad_text(r"{\FArial;A}\P%%d \U+4E2D"), "A\n° 中");
    }

    #[test]
    fn preserves_stacked_values_and_legacy_decimal_codes() {
        assert_eq!(normalize_cad_text(r"\S1^2; %%065"), "1/2 A");
    }

    #[test]
    fn preserves_unknown_vendor_escapes() {
        assert_eq!(normalize_cad_text(r"A\zB"), r"A\zB");
    }

    #[test]
    fn decodes_surrogate_pairs_and_preserves_malformed_unicode() {
        assert_eq!(
            normalize_cad_text(r"\U+D840\U+DC00 \u+D83D\u+DE00"),
            "𠀀 😀"
        );
        assert_eq!(normalize_cad_text(r"\U+D840ABC"), r"\U+D840ABC");
        assert_eq!(normalize_cad_text(r"\U+DC00中文"), r"\U+DC00中文");
        assert_eq!(normalize_cad_text(r"\U+12\PLabel"), "\\U+12\nLabel");
        assert_eq!(normalize_cad_text(r"\U+ZZZZLabel"), r"\U+ZZZZLabel");
    }

    #[test]
    fn preserves_multilingual_labels_and_combining_marks() {
        let text =
            "Español français Русский Ελληνικά\nالعَرَبِيَّة עברית ภาษาไทย हिन्दी 日本語 한글 e\u{301}";
        assert_eq!(normalize_cad_text(text), text);
    }

    #[test]
    fn rebar_grade_codes_map_to_bundled_symbols() {
        assert_eq!(
            normalize_single_line_text("%%130 %%131 %%132 %%133 2\u{85}16"),
            "\u{e130} \u{e131} \u{e132} \u{e133} 2\u{e133}16"
        );
        // A styled MTEXT run keeps its UTF-16 range across the mapping.
        let parsed = parse_mtext("{\\H2x;%%132}20", 1.0);
        assert_eq!(parsed.value, "\u{e132}20");
        assert_eq!((parsed.runs[0].start, parsed.runs[0].end), (0, 1));
    }

    #[test]
    fn hard_spaces_do_not_become_wrapping_spaces_and_percent_escape_is_decoded() {
        assert_eq!(
            normalize_cad_text(r"尺寸\~120 %%% %%Z"),
            "尺寸\u{a0}120 % %%Z"
        );
    }

    #[test]
    fn single_line_text_preserves_literal_braces_paths_and_mtext_like_commands() {
        let literal = r"{中文} C:\Fonts\Noto.otf \P日本語 \H2;Размер \S1^2;";
        assert_eq!(normalize_single_line_text(literal), literal);
        assert_eq!(
            normalize_single_line_text(r"\U+4E2D %%d %%p %%c %%065 %%% %%Z"),
            "中 ° ± ⌀ A % %%Z"
        );
        assert_eq!(normalize_single_line_text(r"%%1 %%12 %%"), r"%%1 %%12 %%");
        assert_eq!(normalize_cad_text(r"{\H2;中文}\P日本語"), "中文\n日本語");
    }
}
