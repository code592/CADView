use crate::affine2d::{transform_geometry, Affine2};
use crate::curves;
use crate::dxf_raw;
use crate::mleader::{self, CmColor, MLeaderModel};
use crate::ocs_curves::{
    ocs_axes_or_world, ocs_entity_circle_or_arc, ocs_world_point, tessellate_bulged_polyline,
};
use crate::text_coordinates::{mtext_axes, ocs_axes, plane, world_point};
use crate::text_normalization::{
    append_text_diagnostics, mtext_background, mtext_columns, mtext_line_spacing, parse_mtext,
    parse_single_line_text, SourceMTextColumns,
};
use crate::units::autocad_unit_id;
use cad_core::{
    fingerprint, CadError, CancellationToken, DiagnosticSeverity, DocumentMetadata, Entity2D,
    Entity2DGeometry, FormatAdapter, FormatCapabilities, FormatDiagnostic, FormatId, Layer,
    OpenedDocument, Point2, Scene2D, SceneDocument, SceneKind, SceneSink, SupportLevel,
    TextHorizontalAlignment2D, TextVerticalAlignment2D,
};
use dxf::{entities::EntityType, Drawing};
use std::{
    collections::{BTreeMap, HashMap},
    io::Cursor,
    path::Path,
};

pub struct DxfAdapter;

impl FormatAdapter for DxfAdapter {
    fn capabilities(&self) -> FormatCapabilities {
        FormatCapabilities {
            format: FormatId::Dxf,
            display_name: "Drawing Exchange Format".to_owned(),
            extensions: vec!["dxf".to_owned(), "dxb".to_owned()],
            scene_kind: SceneKind::TwoD,
            support_level: SupportLevel::Production,
            available: true,
            can_stream: false,
            can_measure: true,
            can_select_topology: false,
            note: Some("Common ASCII/binary DXF entities are normalized to Scene2D".to_owned()),
        }
    }

    fn probe(&self, header: &[u8], path_hint: Option<&Path>) -> u8 {
        if header.starts_with(b"AutoCAD Binary DXF") || header.starts_with(b"AutoCAD DXB 1.0") {
            return 100;
        }
        let text = String::from_utf8_lossy(header);
        if text.contains("SECTION") && (text.contains("HEADER") || text.contains("ENTITIES")) {
            return 95;
        }
        extension_score(path_hint, &["dxf", "dxb"], 35)
    }

    fn open(
        &self,
        bytes: &[u8],
        display_name: &str,
        _source_path: Option<&Path>,
        cancel: &CancellationToken,
        mut sink: Option<&mut dyn SceneSink>,
    ) -> Result<OpenedDocument, CadError> {
        cancel.check()?;
        let (encoding, mut unknown_code_page) = ascii_dxf_encoding(bytes, cancel)?;
        let drawing = Drawing::load_with_encoding(&mut Cursor::new(bytes), encoding)
            .map_err(|error| CadError::InvalidDocument(format!("DXF parse failed: {error}")))?;
        if drawing.header.version < dxf::enums::AcadVersion::R2007
            && dxf::code_page::encoding_from_code_page(&drawing.header.drawing_code_page).is_none()
        {
            unknown_code_page = Some(drawing.header.drawing_code_page.clone());
        }

        let mut layer_ids = BTreeMap::new();
        let mut layers = Vec::new();
        for (index, layer) in drawing.layers().enumerate() {
            let id = index as u64 + 1;
            layer_ids.insert(layer.name.clone(), id);
            layers.push(Layer {
                id,
                name: layer.name.clone(),
                visible: layer.is_layer_on,
                color_argb: layer.color_24_bit.map_or_else(
                    || aci_color(layer.color.index().unwrap_or(7)),
                    |rgb| 0xff000000 | (rgb as u32 & 0xffffff),
                ),
            });
        }
        if layers.is_empty() {
            layer_ids.insert("0".to_owned(), 1);
            layers.push(Layer {
                id: 1,
                name: "0".to_owned(),
                visible: true,
                color_argb: 0xffe5e7eb,
            });
        }

        let top_level = drawing.entities().count();
        if top_level > MAX_DXF_ENTITIES {
            return Err(CadError::ResourceLimit(
                "DXF entity count exceeds 5,000,000".to_owned(),
            ));
        }
        let raw = dxf_raw::scan(
            bytes,
            raw_pair_encoding(&drawing),
            drawing.header.version >= dxf::enums::AcadVersion::R2010,
            cancel,
        )?;
        let mut normalizer = DxfNormalizer {
            drawing: &drawing,
            blocks: drawing
                .blocks()
                .map(|block| (block.name.to_uppercase(), block))
                .collect(),
            raw: &raw,
            block_names: drawing
                .block_records()
                .map(|record| (record.handle.0, record.name.clone()))
                .collect(),
            style_names: drawing
                .styles()
                .map(|style| (style.handle.0, style.name.clone()))
                .collect(),
            layer_ids: &layer_ids,
            layers: &layers,
            entities: Vec::new(),
            next_id: top_level as u64 + 1,
            unsupported: BTreeMap::new(),
            cancel,
        };
        for (index, entity) in drawing.entities().enumerate() {
            if index % 4096 == 0 {
                cancel.check()?;
                if let Some(sink) = sink.as_deref_mut() {
                    sink.progress((index as f32 / (index + 4096) as f32).min(0.9));
                }
            }
            normalizer.append(
                entity,
                Some(index as u64 + 1),
                &Affine2::IDENTITY,
                None,
                &mut Vec::new(),
            )?;
        }
        normalizer.append_raw(None, &Affine2::IDENTITY, None, &mut Vec::new())?;
        let DxfNormalizer {
            entities,
            mut unsupported,
            ..
        } = normalizer;
        for (kind, count) in &raw.discarded {
            *unsupported.entry(kind.clone()).or_default() += count;
        }
        if raw.unreadable_hatches > 0 {
            *unsupported.entry("HATCH".to_owned()).or_default() += raw.unreadable_hatches;
        }
        if raw.unreadable_mleaders > 0 {
            *unsupported.entry("MULTILEADER".to_owned()).or_default() += raw.unreadable_mleaders;
        }

        let mut scene = Scene2D {
            layers,
            entities,
            bounds: None,
        };
        scene.recompute_bounds();
        let mut diagnostics = Vec::new();
        append_text_diagnostics(&scene, &mut diagnostics);
        if let Some(code_page) = unknown_code_page {
            diagnostics.push(FormatDiagnostic {
                code: "dxf.unknown_code_page".to_owned(),
                message: format!("Unknown DXF code page {code_page}; Windows-1252 fallback was used and text may be incorrect"),
                severity: DiagnosticSeverity::Warning,
                entity_id: None,
            });
        }
        let unsupported_total = unsupported.values().sum::<u64>();
        if unsupported_total > 0 {
            let details = unsupported
                .iter()
                .map(|(kind, count)| format!("{kind} {count}"))
                .collect::<Vec<_>>()
                .join(", ");
            diagnostics.push(FormatDiagnostic {
                code: "dxf.unsupported_entities".to_owned(),
                message: format!("{unsupported_total} entities are not rendered yet ({details})"),
                severity: DiagnosticSeverity::Warning,
                entity_id: None,
            });
        }
        let document = OpenedDocument {
            metadata: DocumentMetadata {
                format: FormatId::Dxf,
                display_name: display_name.to_owned(),
                fingerprint: fingerprint(bytes),
                byte_length: bytes.len() as u64,
                units: autocad_unit_id(drawing.header.default_drawing_units as i16)
                    .map(str::to_owned),
                author: None,
            },
            scene: SceneDocument::TwoD(scene),
            diagnostics,
        };
        if let Some(sink) = sink.as_deref_mut() {
            sink.progress(1.0);
            sink.partial(&document);
        }
        Ok(document)
    }
}

/// Detect the ASCII header before decoding any entity or table string. The
/// upstream reader switches to UTF-8 for R2007, but otherwise ignores
/// $DWGCODEPAGE and defaults to Windows-1252.
fn ascii_dxf_encoding(
    bytes: &[u8],
    cancel: &CancellationToken,
) -> Result<(&'static encoding_rs::Encoding, Option<String>), CadError> {
    use encoding_rs::*;
    if bytes.starts_with(b"AutoCAD Binary DXF") || bytes.starts_with(b"AutoCAD DXB") {
        return Ok((WINDOWS_1252, None));
    }
    let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(bytes);
    const MAX_HEADER: usize = 4 * 1024 * 1024;
    let mut lines = bytes[..bytes.len().min(MAX_HEADER)].split(|byte| *byte == b'\n');
    let mut header = false;
    let mut section_pending = false;
    let mut variable: &[u8] = b"";
    let mut version: &[u8] = b"";
    let mut code_page: &[u8] = b"";
    let mut complete = false;
    let mut pairs = 0;
    while let (Some(code), Some(value)) = (lines.next(), lines.next()) {
        pairs += 1;
        if pairs % 1024 == 0 {
            cancel.check()?;
        }
        let code = code.trim_ascii();
        let value = value.trim_ascii();
        if code == b"0" && value == b"SECTION" {
            section_pending = true;
            continue;
        }
        if section_pending && code == b"2" {
            header = value == b"HEADER";
            section_pending = false;
            if !header {
                complete = true;
                break;
            }
            continue;
        }
        if !header {
            continue;
        }
        if code == b"0" && value == b"ENDSEC" {
            complete = true;
            break;
        }
        if code == b"9" {
            variable = value;
        } else if variable == b"$ACADVER" && code == b"1" {
            version = value;
        } else if variable == b"$DWGCODEPAGE" && code == b"3" {
            code_page = value;
        }
    }
    if header && !complete && bytes.len() > MAX_HEADER {
        return Err(CadError::ResourceLimit(
            "DXF text-encoding header exceeds 4 MiB".to_owned(),
        ));
    }
    if version.len() == 6 && version.starts_with(b"AC") && version >= b"AC1021" {
        return Ok((UTF_8, None));
    }
    let name = String::from_utf8_lossy(code_page).to_ascii_lowercase();
    let encoding = dxf::code_page::encoding_from_code_page(&name);
    Ok(match encoding {
        Some(encoding) => (encoding, None),
        None => (
            WINDOWS_1252,
            Some(String::from_utf8_lossy(code_page).into_owned()),
        ),
    })
}

fn style<'a>(drawing: &'a Drawing, name: &str) -> Option<&'a dxf::tables::Style> {
    drawing
        .styles()
        .find(|style| style.name.eq_ignore_ascii_case(name))
}

fn positive(value: f64, fallback: f64) -> f64 {
    if value.is_finite() && value.abs() > 1e-12 {
        value.abs()
    } else if fallback.is_finite() && fallback.abs() > 1e-12 {
        fallback.abs()
    } else {
        1.0
    }
}

fn font_family(style: Option<&dxf::tables::Style>) -> Option<String> {
    let file = style?.primary_font_file_name.trim().replace('\\', "/");
    let name = file.rsplit('/').next()?;
    let (stem, extension) = name.rsplit_once('.')?;
    if !stem.is_empty()
        && (extension.eq_ignore_ascii_case("ttf") || extension.eq_ignore_ascii_case("otf"))
    {
        Some(stem.to_owned())
    } else {
        None
    }
}

fn text_geometry(text: &dxf::entities::Text, drawing: &Drawing) -> Option<Entity2DGeometry> {
    use dxf::enums::{HorizontalTextJustification as H, VerticalTextJustification as V};
    let style = style(drawing, &text.text_style_name);
    let fitted = matches!(text.horizontal_text_justification, H::Aligned | H::Fit)
        && text.vertical_text_justification == V::Baseline;
    let aligned = text.horizontal_text_justification != H::Left
        || text.vertical_text_justification != V::Baseline;
    let first = point2(text.location.x, text.location.y);
    let second = point2(text.second_alignment_point.x, text.second_alignment_point.y);
    let distance = (second.x - first.x).hypot(second.y - first.y);
    let has_fit = fitted && distance.is_finite() && distance > 1e-12;
    let axes = ocs_axes([text.normal.x, text.normal.y, text.normal.z])?;
    let parsed = parse_single_line_text(&text.value);
    let origin = if aligned && !fitted {
        &text.second_alignment_point
    } else {
        &text.location
    };
    Some(Entity2DGeometry::Text {
        origin: world_point(axes, [origin.x, origin.y, origin.z]),
        value: parsed.value,
        height: positive(text.text_height, style.map_or(1.0, |s| s.text_height)),
        height_reference: cad_core::TextHeightReference2D::CapHeight,
        rotation: if has_fit {
            (second.y - first.y).atan2(second.x - first.x)
        } else {
            text.rotation.to_radians()
        },
        width_factor: positive(
            text.relative_x_scale_factor,
            style.map_or(1.0, |s| s.width_factor),
        ),
        oblique_angle: if text.oblique_angle.is_finite() {
            text.oblique_angle.to_radians()
        } else {
            0.0
        },
        horizontal_alignment: if fitted {
            TextHorizontalAlignment2D::Left
        } else {
            match text.horizontal_text_justification {
                H::Center | H::Middle => TextHorizontalAlignment2D::Center,
                H::Right => TextHorizontalAlignment2D::Right,
                _ => TextHorizontalAlignment2D::Left,
            }
        },
        vertical_alignment: if text.horizontal_text_justification == H::Middle {
            TextVerticalAlignment2D::Middle
        } else {
            match text.vertical_text_justification {
                V::Bottom => TextVerticalAlignment2D::Bottom,
                V::Middle => TextVerticalAlignment2D::Middle,
                V::Top => TextVerticalAlignment2D::Top,
                _ => TextVerticalAlignment2D::Baseline,
            }
        },
        target_width: has_fit.then_some(distance),
        uniform_fit: has_fit && text.horizontal_text_justification == H::Aligned,
        wrap_width: None,
        line_spacing: None,
        columns: None,
        background: None,
        mirrored_x: text.is_text_backwards(),
        mirrored_y: text.is_text_upside_down(),
        font_family: font_family(style),
        plane: plane(axes),
        text_runs: parsed.runs,
        text_warnings: parsed.warnings,
    })
}

fn mtext_geometry(
    text: &dxf::entities::MText,
    drawing: &Drawing,
    layer_color: u32,
    entity_color: u32,
    block_color: u32,
) -> Option<Entity2DGeometry> {
    use dxf::enums::AttachmentPoint as A;
    let style = style(drawing, &text.text_style_name);
    let mut value = text.extended_text.concat();
    value.push_str(&text.text);
    let normal = [
        text.extrusion_direction.x,
        text.extrusion_direction.y,
        text.extrusion_direction.z,
    ];
    let ocs = ocs_axes(normal)?;
    // MTEXT has no OCS. The reader converts code 50 to the equivalent WCS
    // direction vector; applying TEXT's arbitrary-axis basis here mirrors it
    // a second time when the extrusion points down or is tilted.
    let axes = mtext_axes(
        normal,
        [
            text.x_axis_direction.x,
            text.x_axis_direction.y,
            text.x_axis_direction.z,
        ],
    )?;
    // Keep the legacy rotation field for the default XY plane. Other planes
    // carry their complete orientation/projection in the linear basis.
    let default_plane = plane(ocs).is_none();
    let height = positive(
        text.initial_text_height,
        style.map_or(1.0, |s| s.text_height),
    );
    let mut parsed = parse_mtext(&value, height);
    let columns = if text.column_type != 0
        && text.drawing_direction != dxf::enums::DrawingDirection::LeftToRight
    {
        // Do not apply horizontal column boxes/masks to unimplemented vertical
        // or style-dependent flow. Preserve the readable diagnosed fallback.
        parsed
            .warnings
            .push("mtext_column_direction_unsupported".to_owned());
        None
    } else if text.has_embedded_column_data {
        mtext_columns(
            SourceMTextColumns {
                kind: text.column_type as i16,
                count: text.column_count as i32,
                width: text.column_width,
                gutter: text.column_gutter,
                defined_height: text.defined_column_height,
                total_width: text.column_total_width,
                heights: &text.column_heights,
                flow_reversed: text.is_column_flow_reversed,
                auto_height: text.is_column_auto_height,
            },
            &parsed.column_breaks,
            &mut parsed.warnings,
        )
    } else {
        None
    };
    if text.column_type != 0 && columns.is_none() {
        parsed.warnings.push("mtext_columns_flattened".to_owned());
    }
    if !text.background_color_name.is_empty() && !text.has_background_rgb {
        parsed
            .warnings
            .push("mtext_named_background_color_fallback".to_owned());
    }
    let line_spacing = mtext_line_spacing(
        text.line_spacing_factor,
        text.line_spacing_style == dxf::enums::MTextLineSpacingStyle::Exact,
        &mut parsed.warnings,
    );
    let mut background = mtext_background(
        if text.background_fill_flags != 0 {
            text.background_fill_flags
        } else {
            text.background_fill_setting as i32
        },
        text.fill_box_scale,
        cad_core::MTextBackgroundColor2D::Explicit,
        if text.has_background_rgb {
            0xff000000 | (text.background_color_rgb as u32 & 0xffffff)
        } else if text.background_fill_color.is_by_entity() {
            entity_color
        } else if text.background_fill_color.is_by_block() {
            block_color
        } else {
            text.background_fill_color
                .index()
                .map(aci_color)
                .unwrap_or(layer_color)
        },
        text.background_fill_color_transparency as u32,
        &mut parsed.warnings,
    );
    if let Some(background) = &mut background {
        background.layout_supported = text.column_type == 0 || columns.is_some();
    }
    // In column mode the ordinary group 41 may contain the overall width or
    // another stale reference width. The column specification is authoritative.
    let paragraph_width =
        if text.column_type != 0 && text.column_width.is_finite() && text.column_width > 0.0 {
            text.column_width
        } else {
            text.reference_rectangle_width
        };
    Some(Entity2DGeometry::Text {
        origin: point2(text.insertion_point.x, text.insertion_point.y),
        value: parsed.value,
        height,
        height_reference: cad_core::TextHeightReference2D::CapHeight,
        rotation: if default_plane {
            text.rotation_angle.to_radians()
        } else {
            0.0
        },
        width_factor: positive(style.map_or(1.0, |s| s.width_factor), 1.0),
        oblique_angle: style.map_or(0.0, |s| s.oblique_angle.to_radians()),
        horizontal_alignment: match text.attachment_point {
            A::TopCenter | A::MiddleCenter | A::BottomCenter => TextHorizontalAlignment2D::Center,
            A::TopRight | A::MiddleRight | A::BottomRight => TextHorizontalAlignment2D::Right,
            _ => TextHorizontalAlignment2D::Left,
        },
        vertical_alignment: match text.attachment_point {
            A::TopLeft | A::TopCenter | A::TopRight => TextVerticalAlignment2D::Top,
            A::MiddleLeft | A::MiddleCenter | A::MiddleRight => TextVerticalAlignment2D::Middle,
            _ => TextVerticalAlignment2D::Bottom,
        },
        target_width: None,
        uniform_fit: false,
        wrap_width: (paragraph_width.is_finite() && paragraph_width > 0.0)
            .then_some(paragraph_width),
        line_spacing: Some(line_spacing),
        columns,
        background,
        mirrored_x: style.is_some_and(|s| s.text_generation_flags & 2 != 0),
        mirrored_y: style.is_some_and(|s| s.text_generation_flags & 4 != 0),
        font_family: font_family(style),
        plane: if default_plane { None } else { plane(axes) },
        text_runs: parsed.runs,
        text_warnings: parsed.warnings,
    })
}

fn raw_color(aci: Option<i16>) -> dxf::Color {
    match aci {
        Some(0) => dxf::Color::by_block(),
        Some(index @ 1..=255) => dxf::Color::from_index(index as u8),
        _ => dxf::Color::by_layer(),
    }
}

/// MULTILEADER text as an MTEXT: the stored location is the top of the text
/// box at the left, center or right according to the text alignment.
fn mleader_mtext(
    text: &mleader::MLeaderText,
    style_names: &HashMap<u64, String>,
) -> dxf::entities::MText {
    use dxf::enums::AttachmentPoint as A;
    let direction = if text.direction.iter().all(|value| *value == 0.0) {
        [1.0, 0.0, 0.0]
    } else {
        text.direction
    };
    dxf::entities::MText {
        insertion_point: dxf::Point::new(text.location[0], text.location[1], text.location[2]),
        initial_text_height: text.height,
        reference_rectangle_width: text.width,
        attachment_point: match text.alignment {
            2 => A::TopCenter,
            3 => A::TopRight,
            _ => A::TopLeft,
        },
        text: text.value.clone(),
        text_style_name: text
            .style_handle
            .and_then(|handle| style_names.get(&handle).cloned())
            .unwrap_or_else(|| "STANDARD".to_owned()),
        extrusion_direction: dxf::Vector::new(text.normal[0], text.normal[1], text.normal[2]),
        x_axis_direction: dxf::Vector::new(direction[0], direction[1], direction[2]),
        // The +Z plane takes its orientation from the rotation field.
        rotation_angle: direction[1].atan2(direction[0]).to_degrees(),
        line_spacing_factor: if text.line_spacing_factor > 0.0 {
            text.line_spacing_factor
        } else {
            1.0
        },
        ..Default::default()
    }
}

const MAX_DXF_ENTITIES: usize = 5_000_000;
const MAX_DXF_BLOCK_DEPTH: usize = 64;

/// Encoding of string values after the header, as resolved by the typed reader.
fn raw_pair_encoding(drawing: &Drawing) -> &'static encoding_rs::Encoding {
    if drawing.header.version >= dxf::enums::AcadVersion::R2007 {
        encoding_rs::UTF_8
    } else {
        dxf::code_page::encoding_from_code_page(&drawing.header.drawing_code_page)
            .unwrap_or(encoding_rs::WINDOWS_1252)
    }
}

/// Properties a block reference passes to its children: layer "0" entities
/// take the reference's layer and ByBlock colors take its color.
#[derive(Clone)]
struct Inherited {
    layer: String,
    color: u32,
}

struct DxfNormalizer<'a> {
    drawing: &'a Drawing,
    blocks: HashMap<String, &'a dxf::Block>,
    raw: &'a dxf_raw::RawScan,
    block_names: HashMap<u64, String>,
    style_names: HashMap<u64, String>,
    layer_ids: &'a BTreeMap<String, u64>,
    layers: &'a [Layer],
    entities: Vec<Entity2D>,
    next_id: u64,
    unsupported: BTreeMap<String, u64>,
    cancel: &'a CancellationToken,
}

impl DxfNormalizer<'_> {
    fn mark_unsupported(&mut self, kind: &str) {
        *self.unsupported.entry(kind.to_owned()).or_default() += 1;
    }

    fn resolve(
        &self,
        layer: &str,
        color: &dxf::Color,
        rgb: Option<u32>,
        inherited: Option<&Inherited>,
    ) -> (String, u64, u32, u32) {
        let layer = match inherited {
            Some(parent) if layer == "0" => parent.layer.clone(),
            _ => layer.to_owned(),
        };
        let layer_id = *self.layer_ids.get(&layer).unwrap_or(&1);
        let layer_color = self
            .layers
            .get(layer_id.saturating_sub(1) as usize)
            .map_or(0xffe5e7eb, |layer| layer.color_argb);
        let block_color = inherited.map_or_else(|| aci_color(7), |parent| parent.color);
        let color_argb = if let Some(rgb) = rgb {
            0xff000000 | (rgb & 0xffffff)
        } else if color.is_by_block() {
            block_color
        } else {
            color.index().map(aci_color).unwrap_or(layer_color)
        };
        (layer, layer_id, layer_color, color_argb)
    }

    fn push(
        &mut self,
        id: &mut Option<u64>,
        layer_id: u64,
        color_argb: u32,
        filled: bool,
        geometry: Entity2DGeometry,
        transform: &Affine2,
    ) -> Result<(), CadError> {
        let Some(geometry) = transform_geometry(geometry, transform) else {
            self.mark_unsupported("DEGENERATE_TRANSFORM");
            return Ok(());
        };
        if self.entities.len() >= MAX_DXF_ENTITIES {
            return Err(CadError::ResourceLimit(
                "DXF block expansion exceeds 5,000,000 entities".to_owned(),
            ));
        }
        if self.entities.len() % 4096 == 0 {
            self.cancel.check()?;
        }
        let id = id.take().unwrap_or_else(|| {
            self.next_id += 1;
            self.next_id - 1
        });
        self.entities.push(Entity2D {
            id,
            layer_id,
            color_argb,
            stroke_width: 0.0,
            filled,
            geometry,
        });
        Ok(())
    }

    fn append(
        &mut self,
        entity: &dxf::entities::Entity,
        mut id: Option<u64>,
        transform: &Affine2,
        inherited: Option<&Inherited>,
        stack: &mut Vec<String>,
    ) -> Result<(), CadError> {
        let common = &entity.common;
        if !common.is_visible {
            return Ok(());
        }
        let rgb = (common.has_color_24_bit || common.color_24_bit != 0)
            .then_some(common.color_24_bit as u32);
        let (layer, layer_id, layer_color, color_argb) =
            self.resolve(&common.layer, &common.color, rgb, inherited);
        let own = Inherited {
            layer,
            color: color_argb,
        };
        match &entity.specific {
            EntityType::Insert(insert) => {
                return self.append_insert(insert, transform, &own, stack);
            }
            EntityType::RotatedDimension(value) => {
                return self.append_dimension(&value.dimension_base, transform, &own, stack);
            }
            EntityType::RadialDimension(value) => {
                return self.append_dimension(&value.dimension_base, transform, &own, stack);
            }
            EntityType::DiameterDimension(value) => {
                return self.append_dimension(&value.dimension_base, transform, &own, stack);
            }
            EntityType::AngularThreePointDimension(value) => {
                return self.append_dimension(&value.dimension_base, transform, &own, stack);
            }
            EntityType::OrdinateDimension(value) => {
                return self.append_dimension(&value.dimension_base, transform, &own, stack);
            }
            _ => {}
        }
        let block_color = inherited.map_or_else(|| aci_color(7), |parent| parent.color);
        match normalize_dxf_entity(
            entity,
            self.drawing,
            layer_color,
            color_argb,
            block_color,
            inherited.is_none(),
        ) {
            Ok(geometries) => {
                for (geometry, filled) in geometries {
                    self.push(&mut id, layer_id, color_argb, filled, geometry, transform)?;
                }
            }
            Err(kind) => self.mark_unsupported(kind),
        }
        Ok(())
    }

    fn append_insert(
        &mut self,
        insert: &dxf::entities::Insert,
        transform: &Affine2,
        own: &Inherited,
        stack: &mut Vec<String>,
    ) -> Result<(), CadError> {
        let name = insert.name.to_uppercase();
        let Some(block) = self.blocks.get(&name).copied() else {
            self.mark_unsupported("INSERT_BLOCK_MISSING");
            return Ok(());
        };
        if stack.contains(&name) || stack.len() >= MAX_DXF_BLOCK_DEPTH {
            self.mark_unsupported("INSERT_BLOCK_CYCLE_OR_DEPTH");
            return Ok(());
        }
        let columns = insert.column_count.max(1) as usize;
        let rows = insert.row_count.max(1) as usize;
        let hatch_count = self
            .raw
            .hatches
            .get(&Some(name.clone()))
            .map_or(0, Vec::len);
        let per_cell = block.entities.len() + hatch_count;
        let cells = columns.saturating_mul(rows);
        if cells.saturating_mul(per_cell.max(1))
            > MAX_DXF_ENTITIES - self.entities.len().min(MAX_DXF_ENTITIES)
        {
            return Err(CadError::ResourceLimit(
                "DXF block expansion exceeds 5,000,000 entities".to_owned(),
            ));
        }
        stack.push(name.clone());
        for row in 0..rows {
            for column in 0..columns {
                let cell =
                    transform.then_after(&insert_transform(insert, &block.base_point, column, row));
                for child in &block.entities {
                    if let EntityType::AttributeDefinition(definition) = &child.specific {
                        // Variable definitions are templates for the INSERT's
                        // ATTRIBs; only constant visible values are displayed.
                        if !definition.is_constant() || definition.is_invisible() {
                            continue;
                        }
                    }
                    self.append(child, None, &cell, Some(own), stack)?;
                }
                self.append_raw(Some(&name), &cell, Some(own), stack)?;
                // ATTRIBs are stored in the INSERT's own coordinate space; an
                // array repeats them with each cell's offset. The pinned reader
                // keeps only the attribute body under an INSERT (not its layer
                // or color), so attributes display with the INSERT's properties.
                let (dx, dy) = insert_cell_offset(insert, column, row);
                let attribute_transform = transform.then_after(&Affine2::translation(dx, dy));
                for attribute in insert.attributes() {
                    if attribute.is_invisible() {
                        continue;
                    }
                    let (_, layer_id, _, color_argb) =
                        self.resolve(&own.layer, &dxf::Color::by_layer(), Some(own.color), None);
                    if let Some(geometry) = text_geometry(&attribute_text(attribute), self.drawing)
                    {
                        self.push(
                            &mut None,
                            layer_id,
                            color_argb,
                            false,
                            geometry,
                            &attribute_transform,
                        )?;
                    }
                }
            }
        }
        stack.pop();
        Ok(())
    }

    /// Renders the anonymous `*D…` block, the authoritative DIMENSION
    /// graphics, exactly as the DWG adapter does. POINT entities in that block
    /// are definition helpers, not visible marks.
    fn append_dimension(
        &mut self,
        dimension: &dxf::entities::DimensionBase,
        transform: &Affine2,
        own: &Inherited,
        stack: &mut Vec<String>,
    ) -> Result<(), CadError> {
        let name = dimension.block_name.trim().to_uppercase();
        let Some(block) = self.blocks.get(&name).copied().filter(|_| !name.is_empty()) else {
            self.mark_unsupported("DIMENSION_GRAPHICS_MISSING");
            return Ok(());
        };
        if stack.contains(&name) {
            self.mark_unsupported("DIMENSION_BLOCK_CYCLE");
            return Ok(());
        }
        stack.push(name.clone());
        for child in &block.entities {
            if matches!(child.specific, EntityType::ModelPoint(_)) {
                continue;
            }
            self.append(child, None, transform, Some(own), stack)?;
        }
        self.append_raw(Some(&name), transform, Some(own), stack)?;
        stack.pop();
        Ok(())
    }

    /// Entities read by the raw pass (HATCH, ACAD_TABLE, MULTILEADER) that
    /// belong to the ENTITIES section (`block` None) or to one block.
    fn append_raw(
        &mut self,
        block: Option<&String>,
        transform: &Affine2,
        inherited: Option<&Inherited>,
        stack: &mut Vec<String>,
    ) -> Result<(), CadError> {
        self.append_hatches(block, transform, inherited)?;
        let raw = self.raw;
        let key = block.cloned();
        for table in raw.tables.get(&key).into_iter().flatten() {
            let Some(own) = self.raw_common(&table.common, inherited) else {
                continue;
            };
            // An ACAD_TABLE is drawn by its anonymous block, inserted at the
            // table origin with its X axis along the horizontal direction.
            // Group 2 names the block; fall back to the 343 block-record
            // handle (also when a writer stored that handle in group 2).
            let name = if self.blocks.contains_key(&table.block_name.to_uppercase()) {
                Some(table.block_name.clone())
            } else {
                table
                    .block_record
                    .or_else(|| u64::from_str_radix(table.block_name.trim(), 16).ok())
                    .and_then(|handle| self.block_names.get(&handle).cloned())
            };
            let Some(name) = name else {
                self.mark_unsupported("TABLE_GRAPHICS_MISSING");
                continue;
            };
            let axes = ocs_axes_or_world(table.normal);
            let insert = dxf::entities::Insert {
                name,
                location: dxf::Point::new(
                    table.insertion[0],
                    table.insertion[1],
                    table.insertion[2],
                ),
                rotation: mleader::table_rotation(table.direction, axes).to_degrees(),
                extrusion_direction: dxf::Vector::new(
                    table.normal[0],
                    table.normal[1],
                    table.normal[2],
                ),
                ..Default::default()
            };
            self.append_insert(&insert, transform, &own, stack)?;
        }
        for leader in raw.mleaders.get(&key).into_iter().flatten() {
            let Some(own) = self.raw_common(&leader.common, inherited) else {
                continue;
            };
            self.append_mleader(&leader.model, transform, &own, stack)?;
        }
        Ok(())
    }

    /// Resolves a raw entity's layer/color, or None when it is invisible.
    fn raw_common(
        &self,
        common: &dxf_raw::RawCommon,
        inherited: Option<&Inherited>,
    ) -> Option<Inherited> {
        if !common.visible {
            return None;
        }
        let color = raw_color(common.color.aci);
        let (layer, _, _, color_argb) =
            self.resolve(&common.layer, &color, common.color.rgb, inherited);
        Some(Inherited {
            layer,
            color: color_argb,
        })
    }

    /// Resolves a MULTILEADER part color. ByBlock parts follow the
    /// MULTILEADER entity itself, as AutoCAD displays them.
    fn part_color(&self, color: CmColor, own: &Inherited) -> (u64, u32) {
        let (dxf_color, rgb) = match color {
            CmColor::ByLayer => (dxf::Color::by_layer(), None),
            CmColor::ByBlock => (dxf::Color::by_block(), None),
            CmColor::Aci(index) => (dxf::Color::from_index(index), None),
            CmColor::Rgb(rgb) => (dxf::Color::by_layer(), Some(rgb)),
        };
        let (_, layer_id, _, color_argb) = self.resolve(&own.layer, &dxf_color, rgb, Some(own));
        (layer_id, color_argb)
    }

    fn append_mleader(
        &mut self,
        model: &MLeaderModel,
        transform: &Affine2,
        own: &Inherited,
        stack: &mut Vec<String>,
    ) -> Result<(), CadError> {
        let arrowhead = mleader::arrowhead_kind(
            model
                .arrowhead_handle
                .and_then(|handle| self.block_names.get(&handle))
                .map(String::as_str),
        );
        let (layer_id, line_color) = self.part_color(model.line_color, own);
        for (geometry, filled) in mleader::leader_geometry(model, arrowhead) {
            self.push(&mut None, layer_id, line_color, filled, geometry, transform)?;
        }
        if let Some(text) = &model.text {
            let (layer_id, color) = self.part_color(text.color, own);
            let layer_color = self
                .layers
                .get(layer_id.saturating_sub(1) as usize)
                .map_or(0xffe5e7eb, |layer| layer.color_argb);
            let paragraph = mleader_mtext(text, &self.style_names);
            if let Some(geometry) =
                mtext_geometry(&paragraph, self.drawing, layer_color, color, own.color)
            {
                self.push(&mut None, layer_id, color, false, geometry, transform)?;
            }
        }
        if let Some(block) = &model.block {
            let Some(name) = self.block_names.get(&block.block_handle).cloned() else {
                self.mark_unsupported("MULTILEADER_BLOCK_MISSING");
                return Ok(());
            };
            let (_, color) = self.part_color(block.color, own);
            let insert = dxf::entities::Insert {
                name,
                location: dxf::Point::new(block.location[0], block.location[1], block.location[2]),
                x_scale_factor: block.scale[0],
                y_scale_factor: block.scale[1],
                z_scale_factor: block.scale[2],
                rotation: block.rotation.to_degrees(),
                extrusion_direction: dxf::Vector::new(
                    block.normal[0],
                    block.normal[1],
                    block.normal[2],
                ),
                ..Default::default()
            };
            let content = Inherited {
                layer: own.layer.clone(),
                color,
            };
            self.append_insert(&insert, transform, &content, stack)?;
        }
        Ok(())
    }

    fn append_hatches(
        &mut self,
        block: Option<&String>,
        transform: &Affine2,
        inherited: Option<&Inherited>,
    ) -> Result<(), CadError> {
        let raw = self.raw;
        let Some(hatches) = raw.hatches.get(&block.cloned()) else {
            return Ok(());
        };
        for hatch in hatches {
            if !hatch.visible {
                continue;
            }
            let color = raw_color(hatch.color.aci);
            let (_, layer_id, _, color_argb) =
                self.resolve(&hatch.layer, &color, hatch.color.rgb, inherited);
            // A solid fill with one boundary has no islands, so filling it is
            // exact. Multi-loop fills and pattern hatches show their outlines.
            let fill = hatch.solid && hatch.loop_count == 1 && hatch.pieces.len() == 1;
            for (points, closed) in &hatch.pieces {
                self.push(
                    &mut None,
                    layer_id,
                    color_argb,
                    fill && *closed,
                    Entity2DGeometry::Polyline {
                        points: points.clone(),
                        closed: *closed,
                    },
                    transform,
                )?;
            }
        }
        Ok(())
    }
}

/// World offset of a MINSERT cell: spacing in the rotated, unscaled
/// insertion frame, projected through the INSERT's OCS.
fn insert_cell_offset(insert: &dxf::entities::Insert, column: usize, row: usize) -> (f64, f64) {
    let axes = ocs_axes_or_world([
        insert.extrusion_direction.x,
        insert.extrusion_direction.y,
        insert.extrusion_direction.z,
    ]);
    let (sin, cos) = insert.rotation.to_radians().sin_cos();
    let x = column as f64 * insert.column_spacing;
    let y = row as f64 * insert.row_spacing;
    let (u, v) = (cos * x - sin * y, sin * x + cos * y);
    (
        axes[0][0] * u + axes[1][0] * v,
        axes[0][1] * u + axes[1][1] * v,
    )
}

/// Block space → parent space: OCS(N) · T(P) · Rz(r) · [T(cell)] · S · T(−B).
/// MINSERT spacing is applied in the rotated, unscaled insertion frame.
fn insert_transform(
    insert: &dxf::entities::Insert,
    base: &dxf::Point,
    column: usize,
    row: usize,
) -> Affine2 {
    let axes = ocs_axes_or_world([
        insert.extrusion_direction.x,
        insert.extrusion_direction.y,
        insert.extrusion_direction.z,
    ]);
    let (sin, cos) = insert.rotation.to_radians().sin_cos();
    let (sx, sy) = (insert.x_scale_factor, insert.y_scale_factor);
    // Linear part in OCS: R · S.
    let (la, lb, lc, ld) = (cos * sx, sin * sx, -sin * sy, cos * sy);
    let cell_x = column as f64 * insert.column_spacing;
    let cell_y = row as f64 * insert.row_spacing;
    let local_tx = -(la * base.x + lc * base.y) + cos * cell_x - sin * cell_y + insert.location.x;
    let local_ty = -(lb * base.x + ld * base.y) + sin * cell_x + cos * cell_y + insert.location.y;
    // OCS axes projected onto world XY.
    let ocs = Affine2 {
        a: axes[0][0],
        b: axes[0][1],
        c: axes[1][0],
        d: axes[1][1],
        tx: axes[2][0] * insert.location.z,
        ty: axes[2][1] * insert.location.z,
    };
    ocs.then_after(&Affine2 {
        a: la,
        b: lb,
        c: lc,
        d: ld,
        tx: local_tx,
        ty: local_ty,
    })
}

fn attribute_text(attribute: &dxf::entities::Attribute) -> dxf::entities::Text {
    dxf::entities::Text {
        thickness: attribute.thickness,
        location: attribute.location.clone(),
        text_height: attribute.text_height,
        value: attribute.value.clone(),
        rotation: attribute.rotation,
        relative_x_scale_factor: attribute.relative_x_scale_factor,
        oblique_angle: attribute.oblique_angle,
        text_style_name: attribute.text_style_name.clone(),
        text_generation_flags: attribute.text_generation_flags,
        horizontal_text_justification: attribute.horizontal_text_justification,
        second_alignment_point: attribute.second_alignment_point.clone(),
        normal: attribute.normal.clone(),
        vertical_text_justification: attribute.vertical_text_justification,
        ..Default::default()
    }
}

fn attribute_definition_text(
    definition: &dxf::entities::AttributeDefinition,
    show_tag: bool,
) -> dxf::entities::Text {
    dxf::entities::Text {
        thickness: definition.thickness,
        location: definition.location.clone(),
        text_height: definition.text_height,
        value: if show_tag {
            definition.text_tag.clone()
        } else {
            definition.value.clone()
        },
        rotation: definition.rotation,
        relative_x_scale_factor: definition.relative_x_scale_factor,
        oblique_angle: definition.oblique_angle,
        text_style_name: definition.text_style_name.clone(),
        text_generation_flags: definition.text_generation_flags,
        horizontal_text_justification: definition.horizontal_text_justification,
        second_alignment_point: definition.second_alignment_point.clone(),
        normal: definition.normal.clone(),
        vertical_text_justification: definition.vertical_text_justification,
        ..Default::default()
    }
}

fn point3(point: &dxf::Point) -> [f64; 3] {
    [point.x, point.y, point.z]
}

/// Converts one non-reference entity into geometry in its owner's space.
/// Returns the entity kind name when it is not rendered.
fn normalize_dxf_entity(
    entity: &dxf::entities::Entity,
    drawing: &Drawing,
    layer_color: u32,
    color_argb: u32,
    block_color: u32,
    top_level: bool,
) -> Result<Vec<(Entity2DGeometry, bool)>, &'static str> {
    let one = |geometry: Option<Entity2DGeometry>, kind: &'static str| {
        geometry.map(|geometry| vec![(geometry, false)]).ok_or(kind)
    };
    match &entity.specific {
        EntityType::ModelPoint(value) => one(
            Some(Entity2DGeometry::Point {
                position: point2(value.location.x, value.location.y),
            }),
            "POINT",
        ),
        EntityType::Line(value) => one(
            Some(Entity2DGeometry::Line {
                start: point2(value.p1.x, value.p1.y),
                end: point2(value.p2.x, value.p2.y),
            }),
            "LINE",
        ),
        // CIRCLE, ARC and 2D polylines are stored in their OCS. Mirrored
        // CAD geometry commonly has a (0, 0, -1) extrusion.
        EntityType::Circle(value) => one(
            Some(dxf_ocs_circle_or_arc(
                &value.center,
                value.radius,
                &value.normal,
                None,
            )),
            "CIRCLE",
        ),
        EntityType::Arc(value) => one(
            Some(dxf_ocs_circle_or_arc(
                &value.center,
                value.radius,
                &value.normal,
                Some((value.start_angle.to_radians(), value.end_angle.to_radians())),
            )),
            "ARC",
        ),
        EntityType::LwPolyline(value) => one(
            Some(Entity2DGeometry::Polyline {
                points: dxf_ocs_bulged_polyline(
                    &value
                        .vertices
                        .iter()
                        .map(|vertex| (vertex.x, vertex.y, vertex.bulge))
                        .collect::<Vec<_>>(),
                    value.is_closed(),
                    entity.common.elevation,
                    &value.extrusion_direction,
                ),
                closed: value.is_closed(),
            }),
            "LWPOLYLINE",
        ),
        EntityType::Polyline(value) => one(dxf_polyline_geometry(value), "POLYLINE_MESH"),
        EntityType::Text(value) => one(text_geometry(value, drawing), "TEXT"),
        EntityType::MText(value) => one(
            mtext_geometry(value, drawing, layer_color, color_argb, block_color),
            "MTEXT",
        ),
        EntityType::Attribute(value) if !value.is_invisible() => {
            one(text_geometry(&attribute_text(value), drawing), "ATTRIB")
        }
        EntityType::Attribute(_) => Ok(Vec::new()),
        // In model space an ATTDEF displays its tag; inside a block only
        // constant definitions reach here and display their value.
        EntityType::AttributeDefinition(value) if !value.is_invisible() => one(
            text_geometry(&attribute_definition_text(value, top_level), drawing),
            "ATTDEF",
        ),
        EntityType::AttributeDefinition(_) => Ok(Vec::new()),
        EntityType::Ellipse(value) => {
            let (points, closed) = curves::tessellate_ellipse(
                point3(&value.center),
                [value.major_axis.x, value.major_axis.y, value.major_axis.z],
                [value.normal.x, value.normal.y, value.normal.z],
                value.minor_axis_ratio,
                value.start_parameter,
                value.end_parameter,
            );
            one(
                Some(Entity2DGeometry::Polyline { points, closed }),
                "ELLIPSE",
            )
        }
        EntityType::Spline(value) => {
            let controls = value.control_points.iter().map(point3).collect::<Vec<_>>();
            let fit = value.fit_points.iter().map(point3).collect::<Vec<_>>();
            let points = curves::tessellate_spline(&curves::SplineSource {
                degree: value.degree_of_curve,
                knots: &value.knot_values,
                control_points: &controls,
                weights: &value.weight_values,
                fit_points: &fit,
                closed: value.is_closed(),
            });
            if points.len() < 2 {
                return Err("SPLINE");
            }
            one(
                Some(Entity2DGeometry::Polyline {
                    points,
                    closed: value.is_closed(),
                }),
                "SPLINE",
            )
        }
        // SOLID and TRACE corners are OCS points in 1-2-4-3 drawing order.
        EntityType::Solid(value) => Ok(vec![(
            solid_outline(
                [
                    &value.first_corner,
                    &value.second_corner,
                    &value.third_corner,
                    &value.fourth_corner,
                ],
                &value.extrusion_direction,
            ),
            true,
        )]),
        EntityType::Trace(value) => Ok(vec![(
            solid_outline(
                [
                    &value.first_corner,
                    &value.second_corner,
                    &value.third_corner,
                    &value.fourth_corner,
                ],
                &value.extrusion_direction,
            ),
            true,
        )]),
        // 3DFACE corners are WCS; the face is shown as its outline.
        EntityType::Face3D(value) => {
            let mut corners = vec![
                point2(value.first_corner.x, value.first_corner.y),
                point2(value.second_corner.x, value.second_corner.y),
                point2(value.third_corner.x, value.third_corner.y),
            ];
            if value.fourth_corner != value.third_corner {
                corners.push(point2(value.fourth_corner.x, value.fourth_corner.y));
            }
            one(
                Some(Entity2DGeometry::Polyline {
                    points: corners,
                    closed: true,
                }),
                "3DFACE",
            )
        }
        EntityType::Leader(value) if value.vertices.len() >= 2 => one(
            Some(Entity2DGeometry::Polyline {
                points: value
                    .vertices
                    .iter()
                    .map(|vertex| point2(vertex.x, vertex.y))
                    .collect(),
                closed: false,
            }),
            "LEADER",
        ),
        EntityType::Leader(_) => Err("LEADER"),
        EntityType::Image(_) => Err("IMAGE"),
        EntityType::Wipeout(_) => Err("WIPEOUT"),
        EntityType::MLine(_) => Err("MLINE"),
        EntityType::Ray(_) => Err("RAY"),
        EntityType::XLine(_) => Err("XLINE"),
        EntityType::Region(_) => Err("REGION"),
        EntityType::Solid3D(_) => Err("3DSOLID"),
        EntityType::Body(_) => Err("BODY"),
        EntityType::Shape(_) => Err("SHAPE"),
        EntityType::Tolerance(_) => Err("TOLERANCE"),
        EntityType::ArcAlignedText(_) => Err("ARCALIGNEDTEXT"),
        EntityType::RText(_) => Err("RTEXT"),
        EntityType::ProxyEntity(_) => Err("ACAD_PROXY_ENTITY"),
        EntityType::OleFrame(_) | EntityType::Ole2Frame(_) => Err("OLEFRAME"),
        EntityType::DgnUnderlay(_) | EntityType::DwfUnderlay(_) | EntityType::PdfUnderlay(_) => {
            Err("UNDERLAY")
        }
        _ => Err("OTHER"),
    }
}

fn solid_outline(corners: [&dxf::Point; 4], normal: &dxf::Vector) -> Entity2DGeometry {
    let axes = ocs_axes_or_world([normal.x, normal.y, normal.z]);
    let world = |corner: &dxf::Point| {
        let point = ocs_world_point(axes, point3(corner));
        point2(point[0], point[1])
    };
    let mut points = vec![world(corners[0]), world(corners[1]), world(corners[3])];
    if corners[3] != corners[2] {
        points.push(world(corners[2]));
    }
    Entity2DGeometry::Polyline {
        points,
        closed: true,
    }
}

fn point2(x: f64, y: f64) -> Point2 {
    Point2::new(x, y)
}

fn dxf_ocs_circle_or_arc(
    center: &dxf::Point,
    radius: f64,
    normal: &dxf::Vector,
    angles: Option<(f64, f64)>,
) -> Entity2DGeometry {
    ocs_entity_circle_or_arc(
        [center.x, center.y, center.z],
        radius,
        [normal.x, normal.y, normal.z],
        angles,
    )
}

fn dxf_ocs_bulged_polyline(
    vertices: &[(f64, f64, f64)],
    closed: bool,
    elevation: f64,
    normal: &dxf::Vector,
) -> Vec<Point2> {
    let axes = ocs_axes_or_world([normal.x, normal.y, normal.z]);
    tessellate_bulged_polyline(vertices, closed, |x, y| {
        let world = ocs_world_point(axes, [x, y, elevation]);
        point2(world[0], world[1])
    })
}

/// Classic POLYLINE: 2D polylines are OCS with bulges, 3D polylines are WCS.
/// Spline-frame control points are construction data, not display vertices.
/// Polyface and polygon meshes are surfaces whose face records carry no
/// location; drawing them as one path would connect stray lines to the origin.
fn dxf_polyline_geometry(polyline: &dxf::entities::Polyline) -> Option<Entity2DGeometry> {
    if polyline.is_polyface_mesh() || polyline.is_3d_polygon_mesh() {
        return None;
    }
    let vertices = polyline
        .vertices()
        .filter(|vertex| !vertex.is_spline_frame_control_point());
    let points = if polyline.is_3d_polyline() {
        vertices
            .map(|vertex| point2(vertex.location.x, vertex.location.y))
            .collect()
    } else {
        dxf_ocs_bulged_polyline(
            &vertices
                .map(|vertex| (vertex.location.x, vertex.location.y, vertex.bulge))
                .collect::<Vec<_>>(),
            polyline.is_closed(),
            polyline.location.z,
            &polyline.normal,
        )
    };
    Some(Entity2DGeometry::Polyline {
        points,
        closed: polyline.is_closed(),
    })
}

fn extension_score(path: Option<&Path>, extensions: &[&str], score: u8) -> u8 {
    path.and_then(Path::extension)
        .and_then(|value| value.to_str())
        .filter(|value| {
            extensions
                .iter()
                .any(|extension| value.eq_ignore_ascii_case(extension))
        })
        .map_or(0, |_| score)
}

fn aci_color(index: u8) -> u32 {
    acadrust::Color::from_index(index as i16)
        .rgb()
        .map_or(0xffe5e7eb, |(r, g, b)| {
            0xff000000 | (r as u32) << 16 | (g as u32) << 8 | b as u32
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    // These small color fixtures are encoded directly from authored group pairs,
    // not by either parser's writer, so black/presence tests are independent.
    fn binary_color_fixture(source: &str) -> Vec<u8> {
        let mut bytes = b"AutoCAD Binary DXF\r\n\x1a\0".to_vec();
        let mut lines = source.lines();
        while let Some(code) = lines.next() {
            let code: u16 = code.parse().unwrap();
            let value = lines.next().unwrap();
            bytes.extend_from_slice(&code.to_le_bytes());
            match code {
                0..=9 | 100 | 101 | 300..=369 | 430 | 1000..=1003 => {
                    bytes.extend_from_slice(value.as_bytes());
                    bytes.push(0);
                }
                10..=59 | 110..=149 | 210..=239 => {
                    bytes.extend_from_slice(&value.parse::<f64>().unwrap().to_le_bytes())
                }
                170..=179 | 270..=289 => {
                    bytes.extend_from_slice(&value.parse::<i16>().unwrap().to_le_bytes())
                }
                290..=299 => bytes.push(value.parse::<u8>().unwrap()),
                62..=79 | 1070 => {
                    bytes.extend_from_slice(&value.parse::<i16>().unwrap().to_le_bytes())
                }
                90..=99 | 420 | 421 => {
                    bytes.extend_from_slice(&value.parse::<i32>().unwrap().to_le_bytes())
                }
                _ => panic!("Unhandled authored fixture code {code}"),
            }
        }
        bytes
    }

    // Authored from the documented R2018 envelope, not from the patched DXF
    // writer. The same tags are encoded independently as ASCII and binary.
    fn embedded_mtext_fixture(column_type: i16, count: i16, auto: bool) -> String {
        let columns = if column_type != 0 {
            format!(
                "72\n{count}\n44\n50\n45\n12.5\n73\n{}\n74\n1\n{}",
                i16::from(auto),
                if column_type == 2 && !auto {
                    "46\n160\n46\n140\n46\n0\n"
                } else {
                    ""
                }
            )
        } else {
            String::new()
        };
        format!("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1032\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nMTEXT\n100\nAcDbEntity\n8\n0\n100\nAcDbMText\n10\n100\n20\n200\n30\n0\n40\n2.5\n41\n62.5\n46\n150\n71\n5\n72\n1\n11\n0\n21\n1\n31\n0\n1\n{{\\H5;日本語}}\\Pالعربية বাংলা\n73\n2\n44\n0.6\n90\n17\n45\n1.5\n63\n7\n421\n16777215\n101\nEmbedded Object\n70\n1\n10\n0\n20\n1\n30\n0\n11\n100\n21\n200\n31\n0\n40\n62.5\n41\n150\n42\n175\n43\n160\n71\n{column_type}\n{columns}1001\nACAD\n1000\nfixture-data\n1070\n7\n0\nLINE\n10\n0\n20\n0\n11\n10\n21\n10\n0\nENDSEC\n0\nEOF\n")
    }

    #[test]
    fn r2018_embedded_mtext_does_not_overwrite_glyph_layout_or_position() {
        for (kind, count, auto) in [(0, 0, false), (1, 3, false), (2, 0, true), (2, 3, false)] {
            let source = embedded_mtext_fixture(kind, count, auto);
            for bytes in [source.as_bytes().to_vec(), binary_color_fixture(&source)] {
                let opened = DxfAdapter
                    .open(
                        &bytes,
                        "embedded.dxf",
                        None,
                        &CancellationToken::default(),
                        None,
                    )
                    .unwrap();
                let SceneDocument::TwoD(scene) = opened.scene else {
                    panic!()
                };
                assert_eq!(scene.entities.len(), 2);
                let Entity2DGeometry::Text {
                    origin,
                    height,
                    rotation,
                    horizontal_alignment,
                    vertical_alignment,
                    line_spacing: Some(spacing),
                    background: Some(background),
                    text_runs,
                    value,
                    text_warnings,
                    wrap_width,
                    columns,
                    ..
                } = &scene.entities[0].geometry
                else {
                    panic!()
                };
                assert_eq!(*origin, Point2::new(100.0, 200.0));
                assert_eq!(*height, 2.5);
                assert!((*rotation - std::f64::consts::FRAC_PI_2).abs() < 1e-12);
                assert!(matches!(
                    horizontal_alignment,
                    TextHorizontalAlignment2D::Center
                ));
                assert!(matches!(
                    vertical_alignment,
                    TextVerticalAlignment2D::Middle
                ));
                assert_eq!(spacing.factor, 0.6);
                assert_eq!(spacing.style, cad_core::MTextLineSpacingStyle2D::Exact);
                assert_eq!(background.scale, 1.5);
                assert_eq!(background.color_argb, 0xffffffff);
                assert_eq!(value, "日本語\nالعربية বাংলা");
                assert_eq!(text_runs[0].style.height_factor, 2.0);
                assert!(!text_warnings.iter().any(|w| w == "mtext_columns_flattened"));
                assert!(background.layout_supported);
                if kind == 0 {
                    assert!(columns.is_none());
                } else {
                    let columns = columns.as_ref().unwrap();
                    assert_eq!(columns.count, 3);
                    assert_eq!(columns.width, 50.0);
                    assert_eq!(columns.gutter, 12.5);
                    assert!(columns.flow_reversed);
                    assert_eq!(columns.auto_height, auto);
                    assert_eq!(
                        columns.defined_height,
                        if kind == 2 && !auto { 0.0 } else { 150.0 }
                    );
                    assert_eq!(
                        columns.heights,
                        if kind == 2 && !auto {
                            vec![160.0, 140.0, 0.0]
                        } else {
                            vec![]
                        }
                    );
                }
                assert_eq!(*wrap_width, Some(if kind == 0 { 62.5 } else { 50.0 }));
            }
        }
    }

    #[test]
    fn vertical_or_style_dependent_columns_are_diagnosed_not_masked_as_horizontal() {
        for direction in [3, 5] {
            let source = embedded_mtext_fixture(1, 3, false)
                .replace("72\n1\n11\n", &format!("72\n{direction}\n11\n"));
            for bytes in [source.as_bytes().to_vec(), binary_color_fixture(&source)] {
                let opened = DxfAdapter
                    .open(
                        &bytes,
                        "vertical.dxf",
                        None,
                        &CancellationToken::default(),
                        None,
                    )
                    .unwrap();
                let SceneDocument::TwoD(scene) = opened.scene else {
                    panic!()
                };
                let Entity2DGeometry::Text {
                    columns,
                    background: Some(mask),
                    text_warnings,
                    value,
                    ..
                } = &scene.entities[0].geometry
                else {
                    panic!()
                };
                assert!(columns.is_none());
                assert!(!mask.layout_supported);
                assert_eq!(value, "日本語\nالعربية বাংলা");
                assert!(text_warnings
                    .iter()
                    .any(|w| w == "mtext_column_direction_unsupported"));
            }
        }
    }

    #[test]
    fn r2018_column_tags_and_trailing_xdata_are_read_in_their_own_namespace() {
        for (kind, count, auto) in [(1, 3, false), (2, 0, true), (2, 3, false)] {
            let source = embedded_mtext_fixture(kind, count, auto);
            for bytes in [source.as_bytes().to_vec(), binary_color_fixture(&source)] {
                let drawing = Drawing::load(&mut Cursor::new(bytes)).unwrap();
                let entity = drawing.entities().next().unwrap();
                let EntityType::MText(text) = &entity.specific else {
                    panic!()
                };
                assert_eq!(text.column_type, kind);
                assert_eq!(text.column_count, i32::from(count));
                assert_eq!(text.column_width, 50.0);
                assert_eq!(text.column_gutter, 12.5);
                assert_eq!(text.is_column_auto_height, auto);
                assert!(text.is_column_flow_reversed);
                assert!(text.has_embedded_column_data);
                assert_eq!(text.defined_column_height, 150.0);
                assert_eq!(text.column_total_width, 175.0);
                assert_eq!(text.column_total_height, 160.0);
                assert_eq!(text.reference_rectangle_width, 62.5);
                assert_eq!(
                    text.column_heights,
                    if kind == 2 && !auto {
                        vec![160.0, 140.0, 0.0]
                    } else {
                        vec![]
                    }
                );
                assert_eq!(entity.common.x_data.len(), 1);
                assert_eq!(entity.common.x_data[0].application_name, "ACAD");
                assert_eq!(drawing.entities().count(), 2);
            }
        }
    }

    #[test]
    fn unknown_embedded_object_does_not_corrupt_mtext_or_consume_the_next_entity() {
        let source =
            embedded_mtext_fixture(1, 3, false).replace("Embedded Object", "Future Object");
        for bytes in [source.as_bytes().to_vec(), binary_color_fixture(&source)] {
            let opened = DxfAdapter
                .open(
                    &bytes,
                    "unknown-embedded.dxf",
                    None,
                    &CancellationToken::default(),
                    None,
                )
                .unwrap();
            let SceneDocument::TwoD(scene) = opened.scene else {
                panic!()
            };
            assert_eq!(scene.entities.len(), 2);
            let Entity2DGeometry::Text {
                origin,
                height,
                rotation,
                line_spacing: Some(spacing),
                background: Some(bg),
                text_warnings,
                ..
            } = &scene.entities[0].geometry
            else {
                panic!()
            };
            assert_eq!(*origin, Point2::new(100.0, 200.0));
            assert_eq!(*height, 2.5);
            assert!((*rotation - std::f64::consts::FRAC_PI_2).abs() < 1e-12);
            assert_eq!(spacing.factor, 0.6);
            assert_eq!(bg.scale, 1.5);
            assert!(text_warnings.is_empty());
        }
    }

    #[test]
    fn embedded_mtext_rejects_excessive_column_height_data_without_panicking() {
        let source = embedded_mtext_fixture(2, 3, false);
        let oversized = source.replace(
            "1001\nACAD\n",
            &format!("{}1001\nACAD\n", "46\n10\n".repeat(4094)),
        );
        let in_block = oversized
            .replace(
                "2\nENTITIES\n",
                "2\nBLOCKS\n0\nBLOCK\n2\nColumns\n10\n0\n20\n0\n30\n0\n",
            )
            .replace("0\nENDSEC\n0\nEOF\n", "0\nENDBLK\n0\nENDSEC\n0\nEOF\n");
        for source in [oversized, in_block] {
            for bytes in [source.as_bytes().to_vec(), binary_color_fixture(&source)] {
                let result = DxfAdapter.open(
                    &bytes,
                    "oversized-columns.dxf",
                    None,
                    &CancellationToken::default(),
                    None,
                );
                let error = result.unwrap_err().to_string();
                assert!(error.contains("4096"), "{error}");
            }
        }
    }

    #[test]
    fn a_malformed_last_entity_cannot_be_reported_as_a_successful_partial_scene() {
        for prefix in ["", "0\nLINE\n10\n0\n20\n0\n11\n10\n21\n10\n"] {
            let source = format!("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1032\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n{prefix}0\nMTEXT\n10\n0\n20\n0\n40\nnot-a-height\n0\nENDSEC\n0\nEOF\n");
            let error = DxfAdapter
                .open(
                    source.as_bytes(),
                    "malformed-last.dxf",
                    None,
                    &CancellationToken::default(),
                    None,
                )
                .unwrap_err()
                .to_string();
            assert!(error.contains("DXF parse failed"), "{error}");
            assert!(error.contains("invalid float literal"), "{error}");
            assert!(!error.contains("expected 0/ENDSEC"), "{error}");
        }
    }

    #[test]
    fn independent_binary_dxf_keeps_layer_rgb_and_true_black_ink_separate() {
        for layer_rgb in [0, 0x123456] {
            let source = format!("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1032\n0\nENDSEC\n0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n0\nLAYER\n2\nInk\n62\n1\n420\n{layer_rgb}\n430\nBook$Layer\n0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nMTEXT\n100\nAcDbEntity\n8\nInk\n62\n3\n420\n0\n430\nBook$Entity\n100\nAcDbMText\n10\n0\n20\n0\n40\n10\n1\n中文 العربية\n90\n1\n421\n16777215\n0\nMTEXT\n100\nAcDbEntity\n8\nInk\n100\nAcDbMText\n10\n0\n20\n30\n40\n10\n1\n日本語 বাংলা\n90\n1\n63\n256\n0\nENDSEC\n0\nEOF\n");
            let bytes = binary_color_fixture(&source);
            let opened = DxfAdapter
                .open(
                    &bytes,
                    "colors.dxf",
                    None,
                    &CancellationToken::default(),
                    None,
                )
                .unwrap();
            let SceneDocument::TwoD(scene) = opened.scene else {
                panic!()
            };
            let expected_layer = 0xff000000 | layer_rgb as u32;
            assert_eq!(
                scene
                    .layers
                    .iter()
                    .find(|l| l.name == "Ink")
                    .unwrap()
                    .color_argb,
                expected_layer
            );
            assert_eq!(scene.entities[0].color_argb, 0xff000000);
            assert_eq!(scene.entities[1].color_argb, expected_layer);
            for (entity, expected_bg) in scene.entities.iter().zip([0xffffffff, expected_layer]) {
                let Entity2DGeometry::Text {
                    background: Some(bg),
                    text_warnings,
                    ..
                } = &entity.geometry
                else {
                    panic!()
                };
                assert_eq!(bg.color_argb, expected_bg);
                assert!(
                    !text_warnings.contains(&"mtext_named_background_color_fallback".to_owned())
                );
            }
        }
    }

    #[test]
    fn explicit_black_ink_is_not_confused_with_absent_true_color() {
        for (kind, fields) in [
            ("LINE", "10\n0\n20\n0\n11\n10\n21\n10\n"),
            ("TEXT", "10\n0\n20\n0\n40\n10\n1\n中文 العربية\n"),
            (
                "MTEXT",
                "100\nAcDbMText\n10\n0\n20\n0\n40\n10\n1\n日本語 বাংলা\n90\n1\n421\n16777215\n",
            ),
        ] {
            for (rgb, expected) in [("420\n0\n", 0xff000000), ("", 0xffff0000)] {
                let source = format!("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1032\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\n{kind}\n100\nAcDbEntity\n8\n0\n62\n1\n{rgb}{fields}0\nENDSEC\n0\nEOF\n");
                let opened = DxfAdapter
                    .open(
                        source.as_bytes(),
                        "ink.dxf",
                        None,
                        &CancellationToken::default(),
                        None,
                    )
                    .unwrap();
                let SceneDocument::TwoD(scene) = opened.scene else {
                    panic!()
                };
                assert_eq!(scene.entities[0].color_argb, expected, "{kind}: {rgb:?}");
            }
        }
    }

    #[test]
    fn layer_true_color_is_inherited_by_ink_and_masks_without_changing_visibility() {
        let source = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1032\n0\nENDSEC\n0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n0\nLAYER\n2\nBlack\n62\n3\n420\n0\n0\nLAYER\n2\nTeal\n62\n1\n420\n1193046\n0\nLAYER\n2\nHidden\n62\n-1\n420\n0\n0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nMTEXT\n100\nAcDbEntity\n8\nBlack\n100\nAcDbMText\n10\n0\n20\n0\n40\n10\n1\n中文 العربية\n90\n1\n421\n16777215\n0\nMTEXT\n100\nAcDbEntity\n8\nTeal\n62\n1\n100\nAcDbMText\n10\n0\n20\n30\n40\n10\n1\n日本語 বাংলা\n90\n1\n63\n256\n0\nTEXT\n100\nAcDbEntity\n8\nHidden\n10\n0\n20\n60\n40\n10\n1\nhidden\n0\nENDSEC\n0\nEOF\n";
        let opened = DxfAdapter
            .open(
                source.as_bytes(),
                "layers.dxf",
                None,
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!()
        };
        assert_eq!(
            scene
                .layers
                .iter()
                .find(|l| l.name == "Black")
                .unwrap()
                .color_argb,
            0xff000000
        );
        assert_eq!(
            scene
                .layers
                .iter()
                .find(|l| l.name == "Teal")
                .unwrap()
                .color_argb,
            0xff123456
        );
        assert!(
            !scene
                .layers
                .iter()
                .find(|l| l.name == "Hidden")
                .unwrap()
                .visible
        );
        assert_eq!(scene.entities[0].color_argb, 0xff000000);
        assert_eq!(scene.entities[1].color_argb, 0xffff0000);
        assert_eq!(scene.entities[2].color_argb, 0xff000000);
        let Entity2DGeometry::Text {
            background: Some(background),
            ..
        } = &scene.entities[1].geometry
        else {
            panic!()
        };
        assert_eq!(background.color_argb, 0xff123456);
    }

    #[test]
    fn mtext_entity_color_name_is_not_mistaken_for_a_named_mask() {
        for fields in [
            "100\nAcDbEntity\n420\n1122867\n430\nBook$Entity\n100\nAcDbMText\n",
            "100\nAcDbMText\n420\n1122867\n430\nBook$Entity\n",
        ] {
            let source = format!("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1032\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nMTEXT\n{fields}8\n0\n10\n0\n20\n0\n40\n10\n1\nالعربية 日本語\n90\n1\n63\n1\n0\nENDSEC\n0\nEOF\n");
            let opened = DxfAdapter
                .open(
                    source.as_bytes(),
                    "named.dxf",
                    None,
                    &CancellationToken::default(),
                    None,
                )
                .unwrap();
            let SceneDocument::TwoD(scene) = opened.scene else {
                panic!()
            };
            assert_eq!(scene.entities[0].color_argb, 0xff112233);
            let Entity2DGeometry::Text {
                background: Some(background),
                text_warnings,
                ..
            } = &scene.entities[0].geometry
            else {
                panic!()
            };
            assert_eq!(background.color_argb, 0xffff0000);
            assert!(!text_warnings.contains(&"mtext_named_background_color_fallback".to_owned()));
        }
    }

    #[test]
    fn true_black_ink_and_indexed_layer_interoperate_with_independent_dxf_writers() {
        use acadrust::{
            entities::{EntityType as AcadEntity, MText},
            tables::Layer as AcadLayer,
            CadDocument, Color, DxfWriter, Vector3,
        };
        let mut drawing = CadDocument::new();
        drawing
            .layers
            .add(AcadLayer::with_color("Ink", Color::from_index(5)))
            .unwrap();
        for (i, color) in [Color::from_rgb(0, 0, 0), Color::ByLayer]
            .into_iter()
            .enumerate()
        {
            let mut paragraph = MText::with_value(
                "中文 العربية 日本語 বাংলা",
                Vector3::new(0.0, i as f64 * 30.0, 0.0),
            );
            paragraph.common.layer = "Ink".to_owned();
            paragraph.common.color = color;
            paragraph.background_fill_flags = 1;
            paragraph.background_color = Color::from_rgb(255, 255, 255);
            drawing.add_entity(AcadEntity::MText(paragraph)).unwrap();
        }
        for writer in [DxfWriter::new(&drawing), DxfWriter::new_binary(&drawing)] {
            let bytes = writer.write_to_vec().unwrap();
            let opened = DxfAdapter
                .open(
                    &bytes,
                    "black.dxf",
                    None,
                    &CancellationToken::default(),
                    None,
                )
                .unwrap();
            let SceneDocument::TwoD(scene) = opened.scene else {
                panic!()
            };
            assert_eq!(
                scene
                    .layers
                    .iter()
                    .find(|l| l.name == "Ink")
                    .unwrap()
                    .color_argb,
                0xff0000ff
            );
            assert_eq!(scene.entities.len(), 2);
            for (entity, color) in scene.entities.iter().zip([0xff000000, 0xff0000ff]) {
                assert_eq!(entity.color_argb, color);
                let Entity2DGeometry::Text {
                    value,
                    background: Some(bg),
                    ..
                } = &entity.geometry
                else {
                    panic!()
                };
                assert_eq!(value, "中文 العربية 日本語 বাংলা");
                assert_eq!(bg.color_argb, 0xffffffff);
            }
        }
    }

    #[test]
    fn direct_byblock_and_mask_color_inheritance_remain_distinct() {
        for (color, mask_color, expected_ink, expected_mask) in [
            (0, 256, aci_color(7), 0xffff0000),
            (5, 257, 0xff0000ff, 0xff0000ff),
            (5, 0, 0xff0000ff, aci_color(7)),
        ] {
            let source = format!("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1032\n0\nENDSEC\n0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n0\nLAYER\n2\nRed\n62\n1\n0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nMTEXT\n100\nAcDbEntity\n8\nRed\n62\n{color}\n100\nAcDbMText\n10\n0\n20\n0\n40\n10\n1\n中文 العربية\n90\n1\n63\n{mask_color}\n0\nENDSEC\n0\nEOF\n");
            let opened = DxfAdapter
                .open(
                    source.as_bytes(),
                    "inheritance.dxf",
                    None,
                    &CancellationToken::default(),
                    None,
                )
                .unwrap();
            let SceneDocument::TwoD(scene) = opened.scene else {
                panic!()
            };
            assert_eq!(scene.entities[0].color_argb, expected_ink);
            let Entity2DGeometry::Text {
                background: Some(bg),
                ..
            } = &scene.entities[0].geometry
            else {
                panic!()
            };
            assert_eq!(bg.color_argb, expected_mask);
        }
    }

    #[test]
    fn mtext_mask_flags_and_black_rgb_are_not_lost_or_confused_with_entity_color() {
        for (flags, rgb, scale, expected) in [
            (
                1,
                "",
                "45\n2.0\n",
                Some((true, false, 2.0, 0xffff0000, false)),
            ),
            (
                17,
                "421\n0\n",
                "",
                Some((true, true, 1.5, 0xff000000, false)),
            ),
            (
                19,
                "421\n16711680\n",
                "45\n1.25\n",
                Some((true, true, 1.25, 0xffff0000, true)),
            ),
            (16, "", "", Some((false, true, 1.5, 0xffff0000, false))),
            (0, "", "", None),
        ] {
            let source = format!("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1032\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nMTEXT\n100\nAcDbEntity\n8\n0\n420\n1122867\n100\nAcDbMText\n10\n0\n20\n0\n40\n10\n1\n中文\\Pالعربية 日本語\n90\n{flags}\n63\n1\n{rgb}{scale}0\nENDSEC\n0\nEOF\n");
            let opened = DxfAdapter
                .open(
                    source.as_bytes(),
                    "mask.dxf",
                    None,
                    &CancellationToken::default(),
                    None,
                )
                .unwrap();
            let SceneDocument::TwoD(scene) = opened.scene else {
                panic!()
            };
            assert_eq!(scene.entities[0].color_argb, 0xff112233);
            let Entity2DGeometry::Text {
                background, value, ..
            } = &scene.entities[0].geometry
            else {
                panic!()
            };
            assert_eq!(value, "中文\nالعربية 日本語");
            assert_eq!(
                background.map(|b| (
                    b.fill,
                    b.frame,
                    b.scale,
                    b.color_argb,
                    b.color_mode == cad_core::MTextBackgroundColor2D::Canvas
                )),
                expected
            );
        }
    }

    #[test]
    fn mtext_mask_interoperates_with_independent_ascii_and_binary_dxf_writer() {
        use acadrust::{
            entities::{EntityType as AcadEntity, MText},
            CadDocument, DxfWriter, Vector3,
        };
        let mut drawing = CadDocument::new();
        let mut paragraph = MText::with_value("中文 العربية", Vector3::ZERO);
        paragraph.common.color = acadrust::Color::from_rgb(17, 34, 51);
        paragraph.background_fill_flags = 17;
        paragraph.background_scale = 2.0;
        paragraph.background_color = acadrust::Color::from_rgb(0, 0, 0);
        drawing.add_entity(AcadEntity::MText(paragraph)).unwrap();
        for writer in [DxfWriter::new(&drawing), DxfWriter::new_binary(&drawing)] {
            let bytes = writer.write_to_vec().unwrap();
            let opened = DxfAdapter
                .open(
                    &bytes,
                    "mask.dxf",
                    None,
                    &CancellationToken::default(),
                    None,
                )
                .unwrap();
            let SceneDocument::TwoD(scene) = opened.scene else {
                panic!()
            };
            assert_eq!(scene.entities[0].color_argb, 0xff112233);
            let Entity2DGeometry::Text {
                background: Some(background),
                ..
            } = &scene.entities[0].geometry
            else {
                panic!()
            };
            assert_eq!(
                (
                    background.fill,
                    background.frame,
                    background.scale,
                    background.color_argb
                ),
                (true, true, 2.0, 0xff000000)
            );
        }
    }

    const SIMPLE_DXF: &[u8] = b"0\nSECTION\n2\nENTITIES\n0\nLINE\n8\n0\n10\n0.0\n20\n0.0\n11\n3.0\n21\n4.0\n0\nCIRCLE\n8\n0\n10\n10.0\n20\n10.0\n40\n2.0\n0\nENDSEC\n0\nEOF\n";

    #[test]
    fn detects_and_opens_ascii_dxf() {
        let adapter = DxfAdapter;
        assert!(adapter.probe(SIMPLE_DXF, None) >= 90);
        let opened = adapter
            .open(
                SIMPLE_DXF,
                "sample.dxf",
                None,
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        match opened.scene {
            SceneDocument::TwoD(scene) => {
                assert_eq!(scene.entities.len(), 2);
                assert!(scene.bounds.is_some());
            }
            _ => panic!("expected a 2D scene"),
        }
    }

    #[test]
    fn preserves_declared_dxf_insertion_units() {
        const MILLIMETER_DXF: &[u8] = b"0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nENDSEC\n0\nEOF\n";
        let opened = DxfAdapter
            .open(
                MILLIMETER_DXF,
                "millimeter.dxf",
                None,
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        assert_eq!(opened.metadata.units.as_deref(), Some("mm"));
    }

    #[test]
    fn legacy_ascii_dxf_honors_declared_text_code_pages() {
        use encoding_rs::*;
        for (name, encoding, label) in [
            ("ANSI_1251", WINDOWS_1251, "Размер"),
            ("ANSI_1253", WINDOWS_1253, "Μέτρηση"),
            ("ANSI_1256", WINDOWS_1256, "العربية"),
            ("ANSI_936", GBK, "图纸尺寸"),
            ("ANSI_950", BIG5, "圖紙尺寸"),
            ("ANSI_932", SHIFT_JIS, "日本語"),
            ("ANSI_949", EUC_KR, "한국어"),
            ("ANSI_874", WINDOWS_874, "ภาษาไทย"),
        ] {
            let source = format!("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n9\n$DWGCODEPAGE\n3\n{name}\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nTEXT\n8\n0\n10\n0\n20\n0\n40\n10\n1\n{label} \\U+4E2D\n0\nENDSEC\n0\nEOF\n");
            let (bytes, _, errors) = encoding.encode(&source);
            assert!(!errors);
            let opened = DxfAdapter
                .open(
                    &bytes,
                    "legacy.dxf",
                    None,
                    &CancellationToken::default(),
                    None,
                )
                .unwrap();
            let SceneDocument::TwoD(scene) = opened.scene else {
                panic!("expected Scene2D")
            };
            let Entity2DGeometry::Text { value, .. } = &scene.entities[0].geometry else {
                panic!("expected text")
            };
            assert_eq!(value, &format!("{label} 中"), "code page {name}");
        }
    }

    #[test]
    fn modern_ascii_dxf_uses_utf8_even_with_legacy_code_page_tag() {
        let bytes = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1021\n9\n$DWGCODEPAGE\n3\nANSI_1251\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nTEXT\n8\n0\n10\n0\n20\n0\n40\n10\n1\nবাংলা 中文 العربية\n0\nENDSEC\n0\nEOF\n".as_bytes();
        let opened = DxfAdapter
            .open(bytes, "utf8.dxf", None, &CancellationToken::default(), None)
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected Scene2D")
        };
        let Entity2DGeometry::Text { value, .. } = &scene.entities[0].geometry else {
            panic!("expected text")
        };
        assert_eq!(value, "বাংলা 中文 العربية");
    }

    // Build group pairs directly, independently of either DXF writer.
    fn binary_fixture(
        version: &str,
        page: &str,
        encoding: &'static encoding_rs::Encoding,
        label: &str,
        small_codes: bool,
    ) -> Vec<u8> {
        fn code(bytes: &mut Vec<u8>, value: u16, small: bool) {
            if small && value < 255 {
                bytes.push(value as u8);
            } else {
                if small {
                    bytes.push(255);
                }
                bytes.extend_from_slice(&value.to_le_bytes());
            }
        }
        fn text(
            bytes: &mut Vec<u8>,
            group: u16,
            value: &str,
            encoding: &'static encoding_rs::Encoding,
            small: bool,
        ) {
            code(bytes, group, small);
            let (encoded, _, errors) = encoding.encode(value);
            assert!(!errors);
            bytes.extend_from_slice(&encoded);
            bytes.push(0);
        }
        let mut bytes = b"AutoCAD Binary DXF\r\n\x1a\0".to_vec();
        for (group, value) in [
            (0, "SECTION"),
            (2, "HEADER"),
            (9, "$ACADVER"),
            (1, version),
            (9, "$DWGCODEPAGE"),
            (3, page),
            (0, "ENDSEC"),
            (0, "SECTION"),
            (2, "ENTITIES"),
            (999, "source comment"),
            (0, "TEXT"),
            (8, label),
            (1, label),
        ] {
            text(&mut bytes, group, value, encoding, small_codes);
        }
        for (group, number) in [(10, 10_f64), (20, 20.), (40, 5.)] {
            code(&mut bytes, group, small_codes);
            bytes.extend_from_slice(&number.to_le_bytes());
        }
        text(&mut bytes, 0, "LINE", encoding, small_codes);
        text(&mut bytes, 8, label, encoding, small_codes);
        for (group, number) in [(10, 0_f64), (20, 0.), (11, 3.), (21, 4.)] {
            code(&mut bytes, group, small_codes);
            bytes.extend_from_slice(&number.to_le_bytes());
        }
        text(&mut bytes, 0, "ENDSEC", encoding, small_codes);
        text(&mut bytes, 0, "EOF", encoding, small_codes);
        bytes
    }

    fn assert_binary_label(bytes: &[u8], label: &str) -> OpenedDocument {
        let opened = DxfAdapter
            .open(
                bytes,
                "binary.dxf",
                None,
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        let SceneDocument::TwoD(scene) = &opened.scene else {
            panic!("expected Scene2D")
        };
        assert_eq!(scene.entities.len(), 2);
        let Entity2DGeometry::Text { value, origin, .. } = &scene.entities[0].geometry else {
            panic!("expected text")
        };
        assert_eq!(value, label);
        assert_eq!(*origin, Point2::new(10., 20.));
        assert!(scene.layers.iter().any(|layer| layer.name == label));
        assert!(
            matches!(scene.entities[1].geometry, Entity2DGeometry::Line { start, end } if start == Point2::new(0., 0.) && end == Point2::new(3., 4.))
        );
        opened
    }

    #[test]
    fn binary_dxf_preserves_legacy_multibyte_text_and_layer_names() {
        use encoding_rs::*;
        for (page, encoding, label) in [
            ("ANSI_1251", WINDOWS_1251, "Размер"),
            ("ANSI_1253", WINDOWS_1253, "Μέτρηση"),
            ("ANSI_1256", WINDOWS_1256, "العربية"),
            ("ANSI_936", GBK, "图纸尺寸"),
            ("ANSI_950", BIG5, "圖紙尺寸"),
            ("ANSI_932", SHIFT_JIS, "日本語"),
            ("ANSI_949", EUC_KR, "한국어"),
            ("ANSI_874", WINDOWS_874, "ภาษาไทย"),
        ] {
            assert_binary_label(
                &binary_fixture("AC1015", page, encoding, label, false),
                label,
            );
        }
    }

    #[test]
    fn binary_r2007_ignores_stale_code_page_and_preserves_utf8() {
        let label = "Размер 中文 বাংলা العربية";
        assert_binary_label(
            &binary_fixture("AC1021", "ANSI_1251", encoding_rs::UTF_8, label, false),
            label,
        );
    }

    #[test]
    fn binary_r12_preserves_single_byte_and_extended_group_codes() {
        assert_binary_label(
            &binary_fixture(
                "AC1009",
                "ANSI_1252",
                encoding_rs::WINDOWS_1252,
                "café €",
                true,
            ),
            "café €",
        );
    }

    #[test]
    fn unknown_code_page_reports_a_warning_for_ascii_and_binary() {
        let bytes = binary_fixture(
            "AC1015",
            "UNKNOWN_PAGE",
            encoding_rs::WINDOWS_1252,
            "plain",
            false,
        );
        let opened = assert_binary_label(&bytes, "plain");
        assert!(opened
            .diagnostics
            .iter()
            .any(|d| d.code == "dxf.unknown_code_page"));
        let ascii = b"0\nSECTION\n2\nHEADER\n9\n$DWGCODEPAGE\n3\nUNKNOWN_PAGE\n0\nENDSEC\n0\nEOF\n";
        let opened = DxfAdapter
            .open(
                ascii,
                "unknown.dxf",
                None,
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        assert!(opened
            .diagnostics
            .iter()
            .any(|d| d.code == "dxf.unknown_code_page"));
    }

    #[test]
    fn encoding_header_scan_is_bounded_and_honors_cancellation() {
        let mut bytes = b"0\nSECTION\n2\nHEADER\n".to_vec();
        bytes.extend(std::iter::repeat_n(b' ', 4 * 1024 * 1024));
        assert!(matches!(
            ascii_dxf_encoding(&bytes, &CancellationToken::default()),
            Err(CadError::ResourceLimit(_))
        ));
        let cancel = CancellationToken::default();
        cancel.cancel();
        assert!(DxfAdapter
            .open(SIMPLE_DXF, "cancel.dxf", None, &cancel, None)
            .is_err());
    }

    fn fixture_text_json(entity: &str) -> serde_json::Value {
        let source = format!("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1021\n0\nENDSEC\n0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nSTYLE\n0\nSTYLE\n2\nCAD\n40\n0\n41\n0.8\n50\n10\n71\n6\n3\nC:\\fonts\\CADView Noto CJK.OTF\n0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n{entity}0\nENDSEC\n0\nEOF\n");
        let opened = DxfAdapter
            .open(
                source.as_bytes(),
                "layout.dxf",
                None,
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected Scene2D")
        };
        assert_eq!(scene.entities.len(), 1);
        serde_json::to_value(&scene.entities[0].geometry).unwrap()
    }

    #[test]
    fn text_preserves_anchor_width_rotation_mirroring_and_style() {
        for h in 0..=2 {
            for v in 0..=3 {
                let entity = format!("0\nTEXT\n8\n0\n10\n10\n20\n20\n11\n100\n21\n200\n40\n8\n1\n中文 Размер\n7\nCAD\n41\n0.75\n50\n30\n51\n15\n71\n6\n72\n{h}\n73\n{v}\n");
                let geometry = fixture_text_json(&entity);
                let expected = if h == 0 && v == 0 {
                    (10.0, 20.0)
                } else {
                    (100.0, 200.0)
                };
                assert_eq!(geometry["origin"]["x"], expected.0);
                assert_eq!(geometry["origin"]["y"], expected.1);
                assert_eq!(
                    geometry["horizontal_alignment"],
                    ["left", "center", "right"][h]
                );
                assert_eq!(
                    geometry["vertical_alignment"],
                    ["baseline", "bottom", "middle", "top"][v]
                );
                assert_eq!(geometry["width_factor"], 0.75);
                assert!(
                    (geometry["rotation"].as_f64().unwrap() - std::f64::consts::PI / 6.).abs()
                        < 1e-12
                );
                assert!(
                    (geometry["oblique_angle"].as_f64().unwrap() - std::f64::consts::PI / 12.)
                        .abs()
                        < 1e-12
                );
                assert_eq!(geometry["font_family"], "CADView Noto CJK");
                assert_eq!(geometry["mirrored_x"], true);
                assert_eq!(geometry["mirrored_y"], true);
            }
        }
    }

    #[test]
    fn text_aligned_and_fit_keep_distinct_height_behavior() {
        for h in [3, 5] {
            let entity = format!(
                "0\nTEXT\n10\n10\n20\n20\n11\n13\n21\n24\n40\n8\n1\n标注\n72\n{h}\n73\n0\n"
            );
            let geometry = fixture_text_json(&entity);
            assert_eq!(geometry["origin"]["x"], 10.0);
            assert_eq!(geometry["origin"]["y"], 20.0);
            assert_eq!(geometry["target_width"], 5.0);
            assert_eq!(geometry["uniform_fit"], h == 3);
            assert!((geometry["rotation"].as_f64().unwrap() - 4_f64.atan2(3.)).abs() < 1e-12);
        }
        let geometry = fixture_text_json(
            "0\nTEXT\n10\n10\n20\n20\n11\n100\n21\n200\n40\n8\n1\nMiddle\n72\n4\n73\n0\n",
        );
        assert_eq!(geometry["horizontal_alignment"], "center");
        assert_eq!(geometry["vertical_alignment"], "middle");
    }

    #[test]
    fn single_line_literals_are_not_interpreted_as_mtext_formatting() {
        let text = fixture_text_json(
            "0\nTEXT\n10\n0\n20\n0\n40\n10\n1\n{中文} \\P日本語 \\H2;Размер \\U+4E2D %%%\n",
        );
        assert_eq!(text["value"], "{中文} \\P日本語 \\H2;Размер 中 %");
        assert_eq!(text["height_reference"], "cap_height");
        let mtext =
            fixture_text_json("0\nMTEXT\n10\n0\n20\n0\n40\n10\n1\n{\\H2;中文}\\P日本語\\~120\n");
        assert_eq!(mtext["value"], "中文\n日本語\u{a0}120");
    }

    #[test]
    fn mtext_angle_and_equivalent_wcs_vector_have_the_same_extruded_plane() {
        for normal in [[0.0, 0.0, -1.0], [0.0, 0.6, 0.8]] {
            for degrees in [0.0_f64, 30.0, 90.0, -45.0] {
                let (sin, cos) = degrees.to_radians().sin_cos();
                let common = format!(
                    "0\nMTEXT\n10\n10\n20\n20\n30\n30\n40\n8\n1\n中文\n210\n{}\n220\n{}\n230\n{}\n",
                    normal[0], normal[1], normal[2]
                );
                let angle = fixture_text_json(&format!("{common}50\n{degrees}\n"));
                let vector = fixture_text_json(&format!("{common}11\n{cos}\n21\n{sin}\n31\n0\n"));
                assert_eq!(angle["origin"], vector["origin"]);
                assert_eq!(
                    angle["plane"], vector["plane"],
                    "MTEXT establishes WCS direction, not TEXT's OCS: {normal:?}, {degrees}"
                );
            }
        }
    }

    #[test]
    fn mtext_chunks_keep_scoped_styles_on_decoded_utf16_text() {
        let geometry = fixture_text_json(
            "0\nMTEXT\n10\n0\n20\n0\n40\n10\n3\nA{\\fCADView Noto CJK|b1|i1;\\H2x;\\L中文\\U+D83D\n1\n\\U+DE00\\l}B{\\H5;\\Oالعربية\\o}\n",
        );
        assert_eq!(geometry["value"], "A中文😀Bالعربية");
        let runs = geometry["text_runs"].as_array().unwrap();
        assert_eq!(
            runs.iter()
                .map(|run| (run["start"].as_u64().unwrap(), run["end"].as_u64().unwrap()))
                .collect::<Vec<_>>(),
            vec![(0, 1), (1, 5), (5, 6), (6, 13)]
        );
        assert_eq!(runs[1]["style"]["font_family"], "CADView Noto CJK");
        assert_eq!(runs[1]["style"]["height_factor"], 2.0);
        assert_eq!(runs[1]["style"]["bold"], true);
        assert_eq!(runs[1]["style"]["italic"], true);
        assert_eq!(runs[1]["style"]["underline"], true);
        assert_eq!(runs[2]["style"]["height_factor"], 1.0);
        assert_eq!(runs[3]["style"]["height_factor"], 0.5);
        assert_eq!(runs[3]["style"]["overline"], true);
        assert!(geometry.get("text_warnings").is_none());
    }

    #[test]
    fn text_uses_ocs_but_mtext_keeps_its_wcs_insertion_and_direction() {
        let negative = fixture_text_json("0\nTEXT\n10\n10\n20\n20\n30\n30\n40\n8\n1\n中文 Размер\n50\n30\n210\n0\n220\n0\n230\n-1\n");
        assert_eq!(
            negative["origin"],
            serde_json::json!({"x": -10.0, "y": 20.0})
        );
        assert_eq!(
            negative["plane"],
            serde_json::json!({"xx": -1.0, "xy": 0.0, "yx": 0.0, "yy": 1.0})
        );
        let tilted = fixture_text_json("0\nTEXT\n10\n10\n20\n20\n30\n30\n11\n100\n21\n200\n31\n300\n72\n1\n40\n8\n1\n倾斜文字\n210\n0\n220\n0.6\n230\n0.8\n");
        assert!((tilted["origin"]["x"].as_f64().unwrap() + 100.0).abs() < 1e-12);
        assert!((tilted["origin"]["y"].as_f64().unwrap() - 20.0).abs() < 1e-12);
        assert!((tilted["plane"]["yy"].as_f64().unwrap() + 0.8).abs() < 1e-12);
        let wcs = fixture_text_json("0\nMTEXT\n10\n10\n20\n20\n30\n30\n40\n8\n1\nWCS 中文\n210\n0\n220\n0\n230\n-1\n11\n1\n21\n0\n31\n0\n");
        assert_eq!(wcs["origin"], serde_json::json!({"x": 10.0, "y": 20.0}));
        assert_eq!(
            wcs["plane"],
            serde_json::json!({"xx": 1.0, "xy": 0.0, "yx": 0.0, "yy": -1.0})
        );
        let angle = fixture_text_json(
            "0\nMTEXT\n10\n10\n20\n20\n40\n8\n1\nAngle\n210\n0\n220\n0\n230\n-1\n50\n0\n",
        );
        assert_eq!(
            angle["plane"],
            serde_json::json!({"xx": 1.0, "xy": 0.0, "yx": 0.0, "yy": -1.0})
        );
    }

    #[test]
    fn mtext_spacing_interoperates_with_independent_ascii_and_binary_writers() {
        use acadrust::{
            entities::{EntityType as AcadEntity, LineSpacingStyle, MText},
            io::dxf::DxfWriter,
            CadDocument,
        };
        let mut drawing = CadDocument::new();
        for factor in [0.25, 0.6, 1.0, 4.0] {
            for (style, exact) in [
                (LineSpacingStyle::AtLeast, false),
                (LineSpacingStyle::Exactly, true),
            ] {
                let mut label = MText::new();
                label.value = format!("{factor}:{exact} 中文\\Pالعربية 日本語");
                label.height = 10.0;
                label.line_spacing_factor = factor;
                label.line_spacing_style = style;
                drawing.add_entity(AcadEntity::MText(label)).unwrap();
            }
        }
        for writer in [DxfWriter::new(&drawing), DxfWriter::new_binary(&drawing)] {
            let bytes = writer.write_to_vec().unwrap();
            let opened = DxfAdapter
                .open(
                    &bytes,
                    "spacing.dxf",
                    None,
                    &CancellationToken::default(),
                    None,
                )
                .unwrap();
            let SceneDocument::TwoD(scene) = opened.scene else {
                panic!()
            };
            assert_eq!(scene.entities.len(), 8);
            for entity in &scene.entities {
                let Entity2DGeometry::Text {
                    value,
                    line_spacing,
                    text_warnings,
                    ..
                } = &entity.geometry
                else {
                    panic!()
                };
                let (factor, exact) = value
                    .split_whitespace()
                    .next()
                    .unwrap()
                    .split_once(':')
                    .unwrap();
                let spacing = line_spacing.unwrap();
                assert_eq!(spacing.factor, factor.parse::<f64>().unwrap());
                assert_eq!(
                    spacing.style == cad_core::MTextLineSpacingStyle2D::Exact,
                    exact == "true"
                );
                assert!(text_warnings.is_empty());
                assert!(value.contains("中文\nالعربية 日本語"));
            }
        }
        let plain = fixture_text_json("0\nTEXT\n10\n0\n20\n0\n40\n10\n1\nA\n");
        assert!(plain.get("line_spacing").is_none());
    }

    #[test]
    fn mtext_rotation_interoperates_with_an_independent_dxf_writer() {
        use acadrust::{
            entities::{EntityType as AcadEntity, MText},
            io::dxf::DxfWriter,
            CadDocument,
        };
        let mut drawing = CadDocument::new();
        for degrees in [-90.0_f64, 0.0, 15.0, 45.0, 90.0, 180.0, 270.0] {
            let mut label = MText::new();
            label.value = format!("angle:{degrees} 中文 Размер");
            label.height = 10.0;
            label.rotation = degrees.to_radians();
            drawing.add_entity(AcadEntity::MText(label)).unwrap();
        }
        for writer in [DxfWriter::new(&drawing), DxfWriter::new_binary(&drawing)] {
            let bytes = writer.write_to_vec().unwrap();
            let opened = DxfAdapter
                .open(
                    &bytes,
                    "independent.dxf",
                    None,
                    &CancellationToken::default(),
                    None,
                )
                .unwrap();
            let SceneDocument::TwoD(scene) = opened.scene else {
                panic!()
            };
            assert_eq!(scene.entities.len(), 7);
            for entity in &scene.entities {
                let Entity2DGeometry::Text {
                    value, rotation, ..
                } = &entity.geometry
                else {
                    panic!()
                };
                let degrees = value
                    .split_whitespace()
                    .next()
                    .unwrap()
                    .strip_prefix("angle:")
                    .unwrap()
                    .parse::<f64>()
                    .unwrap();
                assert!(
                    (rotation.sin() - degrees.to_radians().sin()).abs() < 1e-10,
                    "independently written {degrees} degrees was rendered as {rotation} radians"
                );
                assert!((rotation.cos() - degrees.to_radians().cos()).abs() < 1e-10);
            }
        }
    }

    #[test]
    fn mtext_retains_all_chunks_and_converts_dxf_degrees_to_scene_radians() {
        for (directions, expected_angle) in [
            ("50\n45\n11\n0\n21\n1\n", std::f64::consts::FRAC_PI_2),
            ("11\n0\n21\n1\n50\n45\n", std::f64::consts::FRAC_PI_4),
        ] {
            let entity = format!("0\nMTEXT\n10\n10\n20\n20\n40\n8\n41\n80\n7\nCAD\n71\n9\n3\n中文前段\\P\n3\nРазмер\\P\n1\n日本語末段\n{directions}");
            let geometry = fixture_text_json(&entity);
            assert_eq!(geometry["value"], "中文前段\nРазмер\n日本語末段");
            assert_eq!(geometry["wrap_width"], 80.0);
            assert_eq!(geometry["target_width"], serde_json::Value::Null);
            assert_eq!(geometry["horizontal_alignment"], "right");
            assert_eq!(geometry["vertical_alignment"], "bottom");
            assert_eq!(geometry["width_factor"], 0.8);
            assert_eq!(geometry["font_family"], "CADView Noto CJK");
            assert!((geometry["rotation"].as_f64().unwrap() - expected_angle).abs() < 1e-12);
        }
    }

    // Authored group pairs: a mirrored (0,0,-1) ARC/CIRCLE, bulged LWPOLYLINE
    // and classic POLYLINE, and a polyface mesh whose face record has no
    // location. Expected world geometry follows the Autodesk arbitrary-axis
    // rule independently of the adapter code.
    fn ocs_curve_fixture() -> String {
        let pairs = [
            "0",
            "SECTION",
            "2",
            "HEADER",
            "9",
            "$ACADVER",
            "1",
            "AC1015",
            "0",
            "ENDSEC",
            "0",
            "SECTION",
            "2",
            "ENTITIES",
            "0",
            "ARC",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbCircle",
            "10",
            "3",
            "20",
            "4",
            "30",
            "0",
            "40",
            "2",
            "210",
            "0",
            "220",
            "0",
            "230",
            "-1",
            "100",
            "AcDbArc",
            "50",
            "0",
            "51",
            "90",
            "0",
            "CIRCLE",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbCircle",
            "10",
            "3",
            "20",
            "4",
            "30",
            "0",
            "40",
            "1",
            "210",
            "0",
            "220",
            "0",
            "230",
            "-1",
            "0",
            "LWPOLYLINE",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbPolyline",
            "90",
            "2",
            "70",
            "0",
            "10",
            "0",
            "20",
            "0",
            "42",
            "1",
            "10",
            "2",
            "20",
            "0",
            "0",
            "POLYLINE",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDb2dPolyline",
            "66",
            "1",
            "10",
            "0",
            "20",
            "0",
            "30",
            "0",
            "70",
            "0",
            "0",
            "VERTEX",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbVertex",
            "100",
            "AcDb2dVertex",
            "10",
            "0",
            "20",
            "0",
            "30",
            "0",
            "42",
            "-1",
            "0",
            "VERTEX",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbVertex",
            "100",
            "AcDb2dVertex",
            "10",
            "2",
            "20",
            "0",
            "30",
            "0",
            "0",
            "SEQEND",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "0",
            "POLYLINE",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbPolyFaceMesh",
            "66",
            "1",
            "10",
            "0",
            "20",
            "0",
            "30",
            "0",
            "70",
            "64",
            "71",
            "3",
            "72",
            "1",
            "0",
            "VERTEX",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbVertex",
            "100",
            "AcDbPolyFaceMeshVertex",
            "10",
            "5",
            "20",
            "5",
            "30",
            "0",
            "70",
            "192",
            "0",
            "VERTEX",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbVertex",
            "100",
            "AcDbPolyFaceMeshVertex",
            "10",
            "6",
            "20",
            "5",
            "30",
            "0",
            "70",
            "192",
            "0",
            "VERTEX",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbVertex",
            "100",
            "AcDbPolyFaceMeshVertex",
            "10",
            "5",
            "20",
            "6",
            "30",
            "0",
            "70",
            "192",
            "0",
            "VERTEX",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbFaceRecord",
            "10",
            "0",
            "20",
            "0",
            "30",
            "0",
            "70",
            "128",
            "71",
            "1",
            "72",
            "2",
            "73",
            "3",
            "0",
            "SEQEND",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "0",
            "ENDSEC",
            "0",
            "EOF",
        ];
        pairs.join("\n") + "\n"
    }

    #[test]
    fn ocs_extrusion_and_bulges_produce_world_curves() {
        let source = ocs_curve_fixture();
        for bytes in [source.as_bytes().to_vec(), binary_color_fixture(&source)] {
            let opened = DxfAdapter
                .open(&bytes, "ocs.dxf", None, &CancellationToken::default(), None)
                .unwrap();
            let SceneDocument::TwoD(scene) = opened.scene else {
                panic!()
            };
            assert_eq!(
                scene.entities.len(),
                4,
                "polyface mesh is not drawn as a path"
            );
            assert!(opened
                .diagnostics
                .iter()
                .any(|diagnostic| diagnostic.code == "dxf.unsupported_entities"));

            let Entity2DGeometry::Arc {
                center,
                radius,
                start_angle,
                end_angle,
            } = &scene.entities[0].geometry
            else {
                panic!("{:?}", scene.entities[0].geometry)
            };
            assert!((center.x + 3.0).abs() < 1e-12 && (center.y - 4.0).abs() < 1e-12);
            assert_eq!(*radius, 2.0);
            // OCS 0..90 degrees maps to world (-5, 4)..(-3, 6), stored CCW
            // from (-3, 6) at 90 degrees to (-5, 4) at 180 degrees.
            assert!((start_angle - std::f64::consts::FRAC_PI_2).abs() < 1e-12);
            assert!((end_angle - std::f64::consts::PI).abs() < 1e-12);

            let Entity2DGeometry::Circle { center, radius } = &scene.entities[1].geometry else {
                panic!("{:?}", scene.entities[1].geometry)
            };
            assert!((center.x + 3.0).abs() < 1e-12 && (center.y - 4.0).abs() < 1e-12);
            assert_eq!(*radius, 1.0);

            // Bulge +1 is a counter-clockwise semicircle (below the chord);
            // bulge -1 is clockwise (above the chord). Both end on vertices.
            for (entity, side) in [(&scene.entities[2], -1.0), (&scene.entities[3], 1.0)] {
                let Entity2DGeometry::Polyline { points, closed } = &entity.geometry else {
                    panic!("{:?}", entity.geometry)
                };
                assert!(!closed);
                assert!(points.len() > 3, "bulge was tessellated");
                assert_eq!((points[0].x, points[0].y), (0.0, 0.0));
                let last = points.last().unwrap();
                assert_eq!((last.x, last.y), (2.0, 0.0));
                for point in points {
                    assert!(((point.x - 1.0).hypot(point.y) - 1.0).abs() < 1e-12);
                    assert!(point.y * side >= -1e-12);
                }
                assert!(points
                    .iter()
                    .any(|point| (point.x - 1.0).abs() < 1e-12 && (point.y - side).abs() < 1e-12));
            }
        }
    }

    // Authored R2000 group pairs (no library writer). Block "B" has base point
    // (10, 10); the MINSERT places it at (100, 0), rotated 90 degrees, scale
    // 2, two columns 10 apart. Expected coordinates follow
    // world = P + R(90°)·(2·(block − base)) + R(90°)·(10·column, 0).
    fn block_fixture() -> String {
        let pairs = [
            "0",
            "SECTION",
            "2",
            "HEADER",
            "9",
            "$ACADVER",
            "1",
            "AC1015",
            "0",
            "ENDSEC",
            "0",
            "SECTION",
            "2",
            "TABLES",
            "0",
            "TABLE",
            "2",
            "LAYER",
            "70",
            "4",
            "0",
            "LAYER",
            "100",
            "AcDbSymbolTableRecord",
            "100",
            "AcDbLayerTableRecord",
            "2",
            "0",
            "70",
            "0",
            "62",
            "7",
            "6",
            "CONTINUOUS",
            "0",
            "LAYER",
            "100",
            "AcDbSymbolTableRecord",
            "100",
            "AcDbLayerTableRecord",
            "2",
            "L1",
            "70",
            "0",
            "62",
            "5",
            "6",
            "CONTINUOUS",
            "0",
            "LAYER",
            "100",
            "AcDbSymbolTableRecord",
            "100",
            "AcDbLayerTableRecord",
            "2",
            "L2",
            "70",
            "0",
            "62",
            "4",
            "6",
            "CONTINUOUS",
            "0",
            "LAYER",
            "100",
            "AcDbSymbolTableRecord",
            "100",
            "AcDbLayerTableRecord",
            "2",
            "DIMS",
            "70",
            "0",
            "62",
            "2",
            "6",
            "CONTINUOUS",
            "0",
            "ENDTAB",
            "0",
            "ENDSEC",
            "0",
            "SECTION",
            "2",
            "BLOCKS",
            "0",
            "BLOCK",
            "5",
            "20",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbBlockBegin",
            "2",
            "B",
            "70",
            "2",
            "10",
            "10",
            "20",
            "10",
            "30",
            "0",
            "3",
            "B",
            "1",
            "",
            "0",
            "LINE",
            "5",
            "21",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "62",
            "0",
            "100",
            "AcDbLine",
            "10",
            "10",
            "20",
            "10",
            "30",
            "0",
            "11",
            "12",
            "21",
            "10",
            "31",
            "0",
            "0",
            "CIRCLE",
            "5",
            "22",
            "100",
            "AcDbEntity",
            "8",
            "L2",
            "62",
            "3",
            "100",
            "AcDbCircle",
            "10",
            "11",
            "20",
            "11",
            "30",
            "0",
            "40",
            "0.5",
            "0",
            "LINE",
            "5",
            "23",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "60",
            "1",
            "100",
            "AcDbLine",
            "10",
            "0",
            "20",
            "0",
            "30",
            "0",
            "11",
            "500",
            "21",
            "500",
            "31",
            "0",
            "0",
            "ATTDEF",
            "5",
            "24",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbText",
            "10",
            "10",
            "20",
            "12",
            "30",
            "0",
            "40",
            "1",
            "1",
            "CONST",
            "100",
            "AcDbAttributeDefinition",
            "3",
            "Prompt",
            "2",
            "C",
            "70",
            "2",
            "0",
            "ATTDEF",
            "5",
            "25",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbText",
            "10",
            "10",
            "20",
            "13",
            "30",
            "0",
            "40",
            "1",
            "1",
            "DEFAULT",
            "100",
            "AcDbAttributeDefinition",
            "3",
            "Prompt",
            "2",
            "V",
            "70",
            "0",
            "0",
            "HATCH",
            "5",
            "26",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "62",
            "0",
            "100",
            "AcDbHatch",
            "10",
            "0",
            "20",
            "0",
            "30",
            "0",
            "210",
            "0",
            "220",
            "0",
            "230",
            "1",
            "2",
            "SOLID",
            "70",
            "1",
            "71",
            "0",
            "91",
            "1",
            "92",
            "3",
            "72",
            "0",
            "73",
            "1",
            "93",
            "4",
            "10",
            "10",
            "20",
            "10",
            "10",
            "11",
            "20",
            "10",
            "10",
            "11",
            "20",
            "11",
            "10",
            "10",
            "20",
            "11",
            "97",
            "0",
            "75",
            "0",
            "76",
            "1",
            "98",
            "0",
            "0",
            "ENDBLK",
            "5",
            "27",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbBlockEnd",
            "0",
            "BLOCK",
            "5",
            "30",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbBlockBegin",
            "2",
            "*D1",
            "70",
            "1",
            "10",
            "0",
            "20",
            "0",
            "30",
            "0",
            "3",
            "*D1",
            "1",
            "",
            "0",
            "LINE",
            "5",
            "31",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbLine",
            "10",
            "0",
            "20",
            "-20",
            "30",
            "0",
            "11",
            "5",
            "21",
            "-20",
            "31",
            "0",
            "0",
            "POINT",
            "5",
            "32",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbPoint",
            "10",
            "0",
            "20",
            "-20",
            "30",
            "0",
            "0",
            "ENDBLK",
            "5",
            "33",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbBlockEnd",
            "0",
            "ENDSEC",
            "0",
            "SECTION",
            "2",
            "ENTITIES",
            "0",
            "INSERT",
            "5",
            "40",
            "100",
            "AcDbEntity",
            "8",
            "L1",
            "62",
            "1",
            "100",
            "AcDbMInsertBlock",
            "66",
            "1",
            "2",
            "B",
            "10",
            "100",
            "20",
            "0",
            "30",
            "0",
            "41",
            "2",
            "42",
            "2",
            "43",
            "2",
            "50",
            "90",
            "70",
            "2",
            "71",
            "1",
            "44",
            "10",
            "45",
            "0",
            "0",
            "ATTRIB",
            "5",
            "41",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbText",
            "10",
            "100",
            "20",
            "5",
            "30",
            "0",
            "40",
            "1",
            "1",
            "VAL",
            "100",
            "AcDbAttribute",
            "2",
            "V",
            "70",
            "0",
            "0",
            "SEQEND",
            "5",
            "42",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "0",
            "DIMENSION",
            "5",
            "43",
            "100",
            "AcDbEntity",
            "8",
            "DIMS",
            "100",
            "AcDbDimension",
            "2",
            "*D1",
            "10",
            "5",
            "20",
            "-20",
            "30",
            "0",
            "11",
            "2.5",
            "21",
            "-19",
            "31",
            "0",
            "70",
            "32",
            "1",
            "",
            "3",
            "STANDARD",
            "100",
            "AcDbAlignedDimension",
            "13",
            "0",
            "23",
            "-20",
            "33",
            "0",
            "14",
            "5",
            "24",
            "-20",
            "34",
            "0",
            "100",
            "AcDbRotatedDimension",
            "0",
            "INSERT",
            "5",
            "44",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbBlockReference",
            "2",
            "MISSING",
            "10",
            "0",
            "20",
            "0",
            "30",
            "0",
            "0",
            "HATCH",
            "5",
            "45",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbHatch",
            "10",
            "0",
            "20",
            "0",
            "30",
            "0",
            "210",
            "0",
            "220",
            "0",
            "230",
            "1",
            "2",
            "ANSI31",
            "70",
            "0",
            "71",
            "0",
            "91",
            "3",
            "92",
            "1",
            "93",
            "2",
            "72",
            "1",
            "10",
            "0",
            "20",
            "50",
            "11",
            "4",
            "21",
            "50",
            "72",
            "2",
            "10",
            "2",
            "20",
            "50",
            "40",
            "2",
            "50",
            "0",
            "51",
            "180",
            "73",
            "0",
            "97",
            "0",
            "92",
            "0",
            "93",
            "2",
            "72",
            "3",
            "10",
            "10",
            "20",
            "50",
            "11",
            "2",
            "21",
            "0",
            "40",
            "0.5",
            "50",
            "0",
            "51",
            "180",
            "73",
            "1",
            "72",
            "1",
            "10",
            "8",
            "20",
            "50",
            "11",
            "12",
            "21",
            "50",
            "97",
            "0",
            "92",
            "0",
            "93",
            "2",
            "72",
            "4",
            "94",
            "2",
            "73",
            "0",
            "74",
            "0",
            "95",
            "6",
            "96",
            "3",
            "40",
            "0",
            "40",
            "0",
            "40",
            "0",
            "40",
            "1",
            "40",
            "1",
            "40",
            "1",
            "10",
            "20",
            "20",
            "50",
            "10",
            "21",
            "20",
            "52",
            "10",
            "22",
            "20",
            "50",
            "72",
            "1",
            "10",
            "22",
            "20",
            "50",
            "11",
            "20",
            "21",
            "50",
            "97",
            "0",
            "75",
            "0",
            "76",
            "1",
            "52",
            "0",
            "41",
            "1",
            "77",
            "0",
            "78",
            "0",
            "98",
            "0",
            "0",
            "MULTILEADER",
            "5",
            "46",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbMLeader",
            "270",
            "2",
            "0",
            "ENDSEC",
            "0",
            "EOF",
        ];
        pairs.join("\n") + "\n"
    }

    fn close(a: Point2, x: f64, y: f64) -> bool {
        (a.x - x).abs() < 1e-9 && (a.y - y).abs() < 1e-9
    }

    #[test]
    fn blocks_attributes_dimensions_and_hatches_are_expanded() {
        let source = block_fixture();
        let opened = DxfAdapter
            .open(
                source.as_bytes(),
                "blocks.dxf",
                None,
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!()
        };
        let layer = |name: &str| scene.layers.iter().find(|l| l.name == name).unwrap().id;
        let red = aci_color(1);

        // Layer-0 ByBlock line: inherits the INSERT's layer and color, once
        // per MINSERT column.
        let lines = scene
            .entities
            .iter()
            .filter_map(|e| match e.geometry {
                Entity2DGeometry::Line { start, end } => Some((e, start, end)),
                _ => None,
            })
            .collect::<Vec<_>>();
        for column_offset in [0.0, 10.0] {
            let (entity, ..) = lines
                .iter()
                .find(|(_, start, end)| {
                    close(*start, 100.0, column_offset) && close(*end, 100.0, 4.0 + column_offset)
                })
                .unwrap_or_else(|| panic!("missing MINSERT line at {column_offset}: {lines:?}"));
            assert_eq!(entity.layer_id, layer("L1"));
            assert_eq!(entity.color_argb, red);
        }
        // The invisible line is skipped; the DIMENSION block line is drawn on
        // the DIMENSION's layer, but its definition POINT is not.
        assert!(!lines.iter().any(|(_, _, end)| close(*end, 500.0, 500.0)));
        let dimension = lines
            .iter()
            .find(|(_, start, end)| close(*start, 0.0, -20.0) && close(*end, 5.0, -20.0))
            .expect("dimension block graphics");
        assert_eq!(dimension.0.layer_id, layer("DIMS"));
        assert!(!scene
            .entities
            .iter()
            .any(|e| matches!(e.geometry, Entity2DGeometry::Point { .. })));

        // Circle on its own layer/color, scaled by 2 and rotated.
        let circles = scene
            .entities
            .iter()
            .filter_map(|e| match e.geometry {
                Entity2DGeometry::Circle { center, radius } => Some((e, center, radius)),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(circles.len(), 2);
        assert!(circles
            .iter()
            .any(|(e, center, radius)| close(*center, 98.0, 2.0)
                && *radius == 1.0
                && e.layer_id == layer("L2")
                && e.color_argb == aci_color(3)));

        // Constant ATTDEF value and the INSERT's ATTRIB in every cell; the
        // variable ATTDEF template is not drawn.
        let texts = scene
            .entities
            .iter()
            .filter_map(|e| match &e.geometry {
                Entity2DGeometry::Text {
                    origin,
                    value,
                    plane,
                    ..
                } => Some((value.as_str(), *origin, *plane)),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert!(!texts.iter().any(|t| t.0 == "DEFAULT"));
        for column_offset in [0.0, 10.0] {
            let constant = texts
                .iter()
                .find(|t| t.0 == "CONST" && close(t.1, 96.0, column_offset))
                .unwrap_or_else(|| panic!("{texts:?}"));
            let plane = constant.2.unwrap();
            assert!((plane.xx).abs() < 1e-12 && (plane.xy + 2.0).abs() < 1e-12);
            assert!((plane.yx - 2.0).abs() < 1e-12 && (plane.yy).abs() < 1e-12);
            assert!(texts
                .iter()
                .any(|t| t.0 == "VAL" && close(t.1, 100.0, 5.0 + column_offset)));
        }

        // Solid single-loop block hatch: filled, ByBlock red, transformed.
        let filled = scene
            .entities
            .iter()
            .filter(|e| e.filled)
            .collect::<Vec<_>>();
        assert_eq!(filled.len(), 2);
        let Entity2DGeometry::Polyline { points, closed } = &filled[0].geometry else {
            panic!()
        };
        assert!(*closed && filled[0].color_argb == red);
        for (x, y) in [(100.0, 0.0), (100.0, 2.0), (98.0, 2.0), (98.0, 0.0)] {
            assert!(points.iter().any(|p| close(*p, x, y)), "{points:?}");
        }

        // Model-space pattern hatch outlines (not filled): the clockwise arc
        // edge lies below its chord, the ellipse edge above, and the
        // quadratic spline edge passes through its Bezier midpoint (21, 51).
        let outlines = scene
            .entities
            .iter()
            .filter_map(|e| match &e.geometry {
                Entity2DGeometry::Polyline { points, .. }
                    if !e.filled && points.iter().all(|p| p.y >= 47.0) =>
                {
                    Some(points.clone())
                }
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(outlines.len(), 3, "{outlines:?}");
        let near = |x: f64, y: f64| {
            outlines
                .iter()
                .flatten()
                .any(|p| (p.x - x).abs() < 1e-6 && (p.y - y).abs() < 1e-6)
        };
        assert!(near(2.0, 48.0), "clockwise arc edge must bow downwards");
        assert!(!near(2.0, 52.0));
        assert!(near(10.0, 51.0), "ellipse edge apex");
        assert!(near(21.0, 51.0), "spline edge midpoint");

        let message = opened
            .diagnostics
            .iter()
            .find(|d| d.code == "dxf.unsupported_entities")
            .map(|d| d.message.clone())
            .unwrap();
        assert!(message.contains("INSERT_BLOCK_MISSING 1"), "{message}");
        assert!(message.contains("MULTILEADER 1"), "{message}");
        assert!(!message.contains("HATCH"), "{message}");
    }

    // Authored R2010 MULTILEADER and ACAD_TABLE group pairs (DXF reference
    // "MLEADER"/"ACAD_TABLE"; CmColor 0xC1000000 = ByBlock, 0xC3000001 = ACI 1).
    fn leader_fixture() -> String {
        let leader = |color: &'static str,
                      path: &'static str,
                      text: &'static str,
                      origin: [&'static str; 2]| {
            let [x, y] = origin;
            vec![
                "0",
                "MULTILEADER",
                "5",
                "60",
                "100",
                "AcDbEntity",
                "8",
                "0",
                "62",
                color,
                "100",
                "AcDbMLeader",
                "270",
                "2",
                "300",
                "CONTEXT_DATA{",
                "40",
                "1",
                "10",
                "0",
                "20",
                "0",
                "30",
                "0",
                "41",
                "2.5",
                "140",
                "3",
                "145",
                "0.5",
                "290",
                "1",
                "304",
                text,
                "11",
                "0",
                "21",
                "0",
                "31",
                "1",
                "12",
                "50",
                "22",
                y,
                "32",
                "0",
                "13",
                "1",
                "23",
                "0",
                "33",
                "0",
                "42",
                "0",
                "43",
                "0",
                "44",
                "0",
                "45",
                "1",
                "170",
                "1",
                "90",
                "-1056964608",
                "171",
                "2",
                "172",
                "1",
                "91",
                "-939524096",
                "141",
                "1.5",
                "92",
                "0",
                "291",
                "0",
                "292",
                "0",
                "173",
                "0",
                "293",
                "0",
                "142",
                "0",
                "143",
                "0",
                "294",
                "0",
                "295",
                "0",
                "296",
                "0",
                "110",
                "0",
                "120",
                "0",
                "130",
                "0",
                "111",
                "1",
                "121",
                "0",
                "131",
                "0",
                "112",
                "0",
                "122",
                "1",
                "132",
                "0",
                "297",
                "0",
                "302",
                "LEADER{",
                "290",
                "1",
                "291",
                "1",
                "10",
                "40",
                "20",
                x,
                "30",
                "0",
                "11",
                "1",
                "21",
                "0",
                "31",
                "0",
                "90",
                "0",
                "40",
                "6",
                "304",
                "LEADER_LINE{",
                "10",
                "0",
                "20",
                "0",
                "30",
                "0",
                "10",
                "20",
                "20",
                "20",
                "30",
                "0",
                "91",
                "0",
                "305",
                "}",
                "271",
                "0",
                "303",
                "}",
                "272",
                "9",
                "273",
                "9",
                "301",
                "}",
                "90",
                "0",
                "170",
                path,
                "91",
                "-1023410175",
                "171",
                "-2",
                "290",
                "1",
                "291",
                "1",
                "41",
                "6",
                "42",
                "3",
                "172",
                "2",
            ]
        };
        let mut pairs = vec![
            "0",
            "SECTION",
            "2",
            "HEADER",
            "9",
            "$ACADVER",
            "1",
            "AC1024",
            "0",
            "ENDSEC",
            "0",
            "SECTION",
            "2",
            "BLOCKS",
            "0",
            "BLOCK",
            "5",
            "70",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbBlockBegin",
            "2",
            "*T5",
            "70",
            "1",
            "10",
            "0",
            "20",
            "0",
            "30",
            "0",
            "3",
            "*T5",
            "1",
            "",
            "0",
            "LINE",
            "5",
            "71",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbLine",
            "10",
            "0",
            "20",
            "0",
            "30",
            "0",
            "11",
            "10",
            "21",
            "0",
            "31",
            "0",
            "0",
            "TEXT",
            "5",
            "72",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbText",
            "10",
            "1",
            "20",
            "-3",
            "30",
            "0",
            "40",
            "1",
            "1",
            "R1",
            "100",
            "AcDbText",
            "0",
            "ENDBLK",
            "5",
            "73",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbBlockEnd",
            "0",
            "ENDSEC",
            "0",
            "SECTION",
            "2",
            "ENTITIES",
        ];
        // Visible straight leader whose last leader point is (40, 25).
        pairs.extend(leader("5", "1", "HELLO", ["25", "30"]));
        // Leader type 0 ("none"): only its text is drawn.
        pairs.extend(leader("5", "0", "QUIET", ["125", "130"]));
        pairs.extend([
            "0",
            "ACAD_TABLE",
            "5",
            "80",
            "100",
            "AcDbEntity",
            "8",
            "0",
            "100",
            "AcDbBlockReference",
            "2",
            "*T5",
            "10",
            "100",
            "20",
            "0",
            "30",
            "0",
            "100",
            "AcDbTable",
            "280",
            "0",
            "11",
            "0",
            "21",
            "1",
            "31",
            "0",
            "91",
            "1",
            "92",
            "1",
            "0",
            "ENDSEC",
            "0",
            "EOF",
        ]);
        pairs.join("\n") + "\n"
    }

    #[test]
    fn multileaders_and_tables_are_drawn() {
        let source = leader_fixture();
        for bytes in [source.as_bytes().to_vec(), binary_color_fixture(&source)] {
            let opened = DxfAdapter
                .open(
                    &bytes,
                    "leaders.dxf",
                    None,
                    &CancellationToken::default(),
                    None,
                )
                .unwrap();
            assert!(
                opened
                    .diagnostics
                    .iter()
                    .all(|d| d.code != "dxf.unsupported_entities"),
                "{:?}",
                opened.diagnostics
            );
            let SceneDocument::TwoD(scene) = opened.scene else {
                panic!()
            };
            let red = aci_color(1);
            let blue = aci_color(5);
            // Filled arrowhead at the first vertex, pointing along (1, 1).
            let arrows = scene
                .entities
                .iter()
                .filter(|e| e.filled)
                .collect::<Vec<_>>();
            assert_eq!(arrows.len(), 1, "type-0 leaders draw no arrowhead");
            let Entity2DGeometry::Polyline {
                points,
                closed: true,
            } = &arrows[0].geometry
            else {
                panic!()
            };
            assert!(close(points[0], 0.0, 0.0) && arrows[0].color_argb == red);
            let base = Point2::new(
                (points[1].x + points[2].x) / 2.0,
                (points[1].y + points[2].y) / 2.0,
            );
            assert!(
                close(base, 3.0 / 2f64.sqrt(), 3.0 / 2f64.sqrt()),
                "{points:?}"
            );
            // Leader line continues to the last leader point, then the dogleg.
            let line = scene
                .entities
                .iter()
                .find_map(|e| match &e.geometry {
                    Entity2DGeometry::Polyline {
                        points,
                        closed: false,
                    } if !e.filled => Some((e, points.clone())),
                    _ => None,
                })
                .unwrap();
            assert_eq!(line.1.len(), 3);
            assert!(close(line.1[2], 40.0, 25.0) && line.0.color_argb == red);
            let doglegs = scene
                .entities
                .iter()
                .filter_map(|e| match e.geometry {
                    Entity2DGeometry::Line { start, end } => Some((start, end)),
                    _ => None,
                })
                .collect::<Vec<_>>();
            assert!(doglegs
                .iter()
                .any(|(s, e)| close(*s, 40.0, 25.0) && close(*e, 46.0, 25.0)));
            assert!(!doglegs.iter().any(|(s, _)| close(*s, 40.0, 125.0)));
            // Center-aligned text at the top of its box, ByBlock → entity blue.
            let texts = scene
                .entities
                .iter()
                .filter_map(|e| match &e.geometry {
                    Entity2DGeometry::Text {
                        origin,
                        value,
                        height,
                        horizontal_alignment,
                        vertical_alignment,
                        ..
                    } => Some((
                        e.color_argb,
                        value.as_str(),
                        *origin,
                        *height,
                        *horizontal_alignment,
                        *vertical_alignment,
                    )),
                    _ => None,
                })
                .collect::<Vec<_>>();
            let hello = texts.iter().find(|t| t.1 == "HELLO").unwrap();
            assert_eq!(hello.0, blue);
            assert!(close(hello.2, 50.0, 30.0) && hello.3 == 2.5);
            assert!(matches!(hello.4, TextHorizontalAlignment2D::Center));
            assert!(matches!(hello.5, TextVerticalAlignment2D::Top));
            assert!(texts
                .iter()
                .any(|t| t.1 == "QUIET" && close(t.2, 50.0, 130.0)));
            // Table block rotated 90° by its (0, 1) direction at (100, 0).
            assert!(doglegs
                .iter()
                .any(|(s, e)| close(*s, 100.0, 0.0) && close(*e, 100.0, 10.0)));
            assert!(texts.iter().any(|t| t.1 == "R1" && close(t.2, 103.0, 1.0)));
        }
    }
}
