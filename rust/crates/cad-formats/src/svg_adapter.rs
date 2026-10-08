use cad_core::TextGeometry2D;
use cad_core::{
    fingerprint, CadError, CancellationToken, DiagnosticSeverity, DocumentMetadata, Entity2D,
    Entity2DGeometry, FormatAdapter, FormatCapabilities, FormatDiagnostic, FormatId, Layer,
    OpenedDocument, Point2, Scene2D, SceneDocument, SceneKind, SceneSink, SupportLevel,
};
use flate2::read::GzDecoder;
use std::{io::Read, path::Path};

pub struct SvgAdapter;

impl FormatAdapter for SvgAdapter {
    fn capabilities(&self) -> FormatCapabilities {
        FormatCapabilities {
            format: FormatId::Svg,
            display_name: "Scalable Vector Graphics".to_owned(),
            extensions: vec!["svg".to_owned(), "svgz".to_owned()],
            scene_kind: SceneKind::TwoD,
            support_level: SupportLevel::Beta,
            available: true,
            can_stream: false,
            can_measure: true,
            can_select_topology: false,
            note: Some("Lines, rectangles, circles, ellipses, polylines, polygons and text are normalized; complex paths are reported".to_owned()),
        }
    }

    fn probe(&self, header: &[u8], path: Option<&Path>) -> u8 {
        if header.starts_with(&[0x1f, 0x8b]) {
            return extension_score(path, &["svgz"], 90);
        }
        let text = String::from_utf8_lossy(header);
        if text.contains("<svg") {
            100
        } else {
            extension_score(path, &["svg", "svgz"], 35)
        }
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
        let xml = if bytes.starts_with(&[0x1f, 0x8b]) {
            const MAX_EXPANDED_SVG_BYTES: u64 = 256 * 1024 * 1024;
            let mut output = String::new();
            GzDecoder::new(bytes)
                .take(MAX_EXPANDED_SVG_BYTES + 1)
                .read_to_string(&mut output)
                .map_err(CadError::Io)?;
            if output.len() as u64 > MAX_EXPANDED_SVG_BYTES {
                return Err(CadError::ResourceLimit(
                    "expanded SVGZ exceeds 256 MiB".to_owned(),
                ));
            }
            output
        } else {
            std::str::from_utf8(bytes)
                .map_err(|error| CadError::InvalidDocument(format!("SVG is not UTF-8: {error}")))?
                .to_owned()
        };
        let xml = strip_doctype(&xml)?;
        let parsed = roxmltree::Document::parse(&xml)
            .map_err(|error| CadError::InvalidDocument(format!("SVG XML failed: {error}")))?;
        let mut entities = Vec::new();
        let mut unsupported_paths = 0_u64;

        for node in parsed.descendants().filter(roxmltree::Node::is_element) {
            cancel.check()?;
            if entities.len() >= 5_000_000 {
                return Err(CadError::ResourceLimit(
                    "SVG entity count exceeds 5,000,000".to_owned(),
                ));
            }
            let geometry = match node.tag_name().name() {
                "line" => Some(Entity2DGeometry::Line {
                    start: Point2::new(number(&node, "x1"), -number(&node, "y1")),
                    end: Point2::new(number(&node, "x2"), -number(&node, "y2")),
                }),
                "rect" => {
                    let x = number(&node, "x");
                    let y = -number(&node, "y");
                    let width = number(&node, "width");
                    let height = number(&node, "height");
                    Some(Entity2DGeometry::Polyline {
                        points: vec![
                            Point2::new(x, y),
                            Point2::new(x + width, y),
                            Point2::new(x + width, y - height),
                            Point2::new(x, y - height),
                        ],
                        closed: true,
                    })
                }
                "circle" => Some(Entity2DGeometry::Circle {
                    center: Point2::new(number(&node, "cx"), -number(&node, "cy")),
                    radius: number(&node, "r").abs(),
                }),
                "ellipse" => {
                    let center = Point2::new(number(&node, "cx"), -number(&node, "cy"));
                    let rx = number(&node, "rx").abs();
                    let ry = number(&node, "ry").abs();
                    Some(Entity2DGeometry::Polyline {
                        points: (0..64)
                            .map(|index| {
                                let angle = std::f64::consts::TAU * index as f64 / 64.0;
                                Point2::new(
                                    center.x + rx * angle.cos(),
                                    center.y + ry * angle.sin(),
                                )
                            })
                            .collect(),
                        closed: true,
                    })
                }
                "polyline" | "polygon" => Some(Entity2DGeometry::Polyline {
                    points: parse_points(node.attribute("points").unwrap_or_default()),
                    closed: node.tag_name().name() == "polygon",
                }),
                "text" => Some(Entity2DGeometry::Text(Box::new(TextGeometry2D {
                    // SVG has a downward Y axis. Scene2D uses an upward Y axis;
                    // convert the insertion point, not the upright glyph shape.
                    origin: Point2::new(number(&node, "x"), -number(&node, "y")),
                    value: node
                        .descendants()
                        .filter(roxmltree::Node::is_text)
                        .filter_map(|child| child.text())
                        .collect(),
                    height: style_number(&node, "font-size").unwrap_or(16.0),
                    height_reference: cad_core::TextHeightReference2D::Em,
                    rotation: 0.0,
                    width_factor: 1.0,
                    oblique_angle: 0.0,
                    horizontal_alignment: Default::default(),
                    vertical_alignment: Default::default(),
                    target_width: None,
                    uniform_fit: false,
                    wrap_width: None,
                    line_spacing: None,
                    columns: None,
                    background: None,
                    mirrored_x: false,
                    mirrored_y: false,
                    font_family: None,
                    shx: None,
                    text_runs: Vec::new(),
                    text_warnings: Vec::new(),
                    plane: None,
                }))),
                "path" => {
                    unsupported_paths += 1;
                    None
                }
                _ => None,
            };
            if let Some(geometry) = geometry {
                entities.push(Entity2D {
                    id: entities.len() as u64 + 1,
                    layer_id: 1,
                    color_argb: 0xffe5e7eb,
                    stroke_width: 0.0,
                    filled: false,
                    dash: Vec::new(),
                    geometry,
                });
            }
        }
        let mut scene = Scene2D {
            layers: vec![Layer {
                id: 1,
                name: "SVG".to_owned(),
                visible: true,
                color_argb: 0xffe5e7eb,
            }],
            entities,
            bounds: None,
        };
        scene.recompute_bounds();
        let mut diagnostics = Vec::new();
        if unsupported_paths > 0 {
            diagnostics.push(FormatDiagnostic {
                code: "svg.complex_paths_pending".to_owned(),
                message: format!(
                    "{unsupported_paths} path elements require the resvg path adapter"
                ),
                severity: DiagnosticSeverity::Warning,
                entity_id: None,
            });
        }
        let document = OpenedDocument {
            metadata: DocumentMetadata {
                format: FormatId::Svg,
                display_name: display_name.to_owned(),
                fingerprint: fingerprint(bytes),
                byte_length: bytes.len() as u64,
                units: None,
                author: None,
                frames: Vec::new(),
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

fn strip_doctype(xml: &str) -> Result<String, CadError> {
    let bytes = xml.as_bytes();
    let start = bytes
        .windows(b"<!DOCTYPE".len())
        .position(|window| window.eq_ignore_ascii_case(b"<!DOCTYPE"));
    let Some(start) = start else {
        return Ok(xml.to_owned());
    };
    let mut quote = None;
    let mut subset_depth = 0_u32;
    for index in start + b"<!DOCTYPE".len()..bytes.len() {
        let byte = bytes[index];
        if let Some(expected) = quote {
            if byte == expected {
                quote = None;
            }
            continue;
        }
        match byte {
            b'\'' | b'"' => quote = Some(byte),
            b'[' => subset_depth = subset_depth.saturating_add(1),
            b']' => subset_depth = subset_depth.saturating_sub(1),
            b'>' if subset_depth == 0 => {
                let mut sanitized = String::with_capacity(xml.len());
                sanitized.push_str(&xml[..start]);
                sanitized.push_str(&xml[index + 1..]);
                return Ok(sanitized);
            }
            _ => {}
        }
    }
    Err(CadError::InvalidDocument(
        "SVG has an unterminated DOCTYPE declaration".to_owned(),
    ))
}

fn number(node: &roxmltree::Node<'_, '_>, name: &str) -> f64 {
    node.attribute(name)
        .and_then(parse_svg_number)
        .unwrap_or(0.0)
}

fn parse_svg_number(value: &str) -> Option<f64> {
    let trimmed = value.trim();
    let end = trimmed
        .find(|character: char| {
            !(character.is_ascii_digit() || matches!(character, '.' | '-' | '+' | 'e' | 'E'))
        })
        .unwrap_or(trimmed.len());
    trimmed[..end].parse().ok()
}

fn style_number(node: &roxmltree::Node<'_, '_>, name: &str) -> Option<f64> {
    if let Some(value) = node.attribute(name).and_then(parse_svg_number) {
        return Some(value);
    }
    node.attribute("style")?.split(';').find_map(|property| {
        let (key, value) = property.split_once(':')?;
        (key.trim() == name)
            .then(|| parse_svg_number(value))
            .flatten()
    })
}

fn parse_points(value: &str) -> Vec<Point2> {
    let values = value
        .split(|character: char| character.is_ascii_whitespace() || character == ',')
        .filter(|value| !value.is_empty())
        .filter_map(|value| value.parse::<f64>().ok())
        .collect::<Vec<_>>();
    values
        .chunks_exact(2)
        .map(|pair| Point2::new(pair[0], -pair[1]))
        .collect()
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opens_basic_svg_geometry() {
        let bytes = br#"<svg xmlns="http://www.w3.org/2000/svg"><line x1="0" y1="1" x2="2" y2="3"/><circle cx="5" cy="5" r="2"/></svg>"#;
        let opened = SvgAdapter
            .open(
                bytes,
                "sample.svg",
                None,
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        match opened.scene {
            SceneDocument::TwoD(scene) => {
                assert_eq!(scene.entities.len(), 2);
                let Entity2DGeometry::Line { start, end } = scene.entities[0].geometry else {
                    panic!("expected line");
                };
                assert_eq!(start, Point2::new(0.0, -1.0));
                assert_eq!(end, Point2::new(2.0, -3.0));
                assert_eq!(
                    parse_points("1,2 3,4"),
                    vec![Point2::new(1.0, -2.0), Point2::new(3.0, -4.0)]
                );
            }
            _ => panic!("expected a 2D scene"),
        }
    }

    #[test]
    fn ignores_external_svg_dtd_without_enabling_entity_expansion() {
        let xml = r#"<?xml version="1.0"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg xmlns="http://www.w3.org/2000/svg"><text x="1" y="2"><tspan>中文</tspan><tspan>CAD</tspan></text></svg>"#;
        let opened = SvgAdapter
            .open(
                xml.as_bytes(),
                "dtd.svg",
                None,
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected a 2D scene");
        };
        let Entity2DGeometry::Text(text_geometry) = &scene.entities[0].geometry else {
            panic!("expected text");
        };
        let TextGeometry2D {
            value,
            height_reference,
            ..
        } = &**text_geometry;
        assert_eq!(value, "中文CAD");
        assert_eq!(*height_reference, cad_core::TextHeightReference2D::Em);
    }
}
