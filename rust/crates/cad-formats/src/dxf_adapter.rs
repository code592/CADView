use crate::text_normalization::normalize_cad_text;
use cad_core::{
    fingerprint, CadError, CancellationToken, DiagnosticSeverity, DocumentMetadata, Entity2D,
    Entity2DGeometry, FormatAdapter, FormatCapabilities, FormatDiagnostic, FormatId, Layer,
    OpenedDocument, Point2, Scene2D, SceneDocument, SceneKind, SceneSink, SupportLevel,
};
use dxf::{entities::EntityType, Drawing};
use std::{collections::BTreeMap, io::Cursor, path::Path};

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
        let drawing = Drawing::load(&mut Cursor::new(bytes))
            .map_err(|error| CadError::InvalidDocument(format!("DXF parse failed: {error}")))?;

        let mut layer_ids = BTreeMap::new();
        let mut layers = Vec::new();
        for (index, layer) in drawing.layers().enumerate() {
            let id = index as u64 + 1;
            layer_ids.insert(layer.name.clone(), id);
            layers.push(Layer {
                id,
                name: layer.name.clone(),
                visible: layer.is_layer_on,
                color_argb: aci_color(layer.color.index().unwrap_or(7)),
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

        let mut entities = Vec::new();
        let mut unsupported = 0_u64;
        for (index, entity) in drawing.entities().enumerate() {
            if index >= 5_000_000 {
                return Err(CadError::ResourceLimit(
                    "DXF entity count exceeds 5,000,000".to_owned(),
                ));
            }
            if index % 4096 == 0 {
                cancel.check()?;
                if let Some(sink) = sink.as_deref_mut() {
                    sink.progress((index as f32 / (index + 4096) as f32).min(0.9));
                }
            }
            let layer_id = *layer_ids.get(&entity.common.layer).unwrap_or(&1);
            let color_argb = entity
                .common
                .color
                .index()
                .map(aci_color)
                .unwrap_or(0xffe5e7eb);
            let geometry = match &entity.specific {
                EntityType::ModelPoint(value) => Some(Entity2DGeometry::Point {
                    position: point2(value.location.x, value.location.y),
                }),
                EntityType::Line(value) => Some(Entity2DGeometry::Line {
                    start: point2(value.p1.x, value.p1.y),
                    end: point2(value.p2.x, value.p2.y),
                }),
                EntityType::Circle(value) => Some(Entity2DGeometry::Circle {
                    center: point2(value.center.x, value.center.y),
                    radius: value.radius.abs(),
                }),
                EntityType::Arc(value) => Some(Entity2DGeometry::Arc {
                    center: point2(value.center.x, value.center.y),
                    radius: value.radius.abs(),
                    start_angle: value.start_angle.to_radians(),
                    end_angle: value.end_angle.to_radians(),
                }),
                EntityType::LwPolyline(value) => Some(Entity2DGeometry::Polyline {
                    points: value
                        .vertices
                        .iter()
                        .map(|point| point2(point.x, point.y))
                        .collect(),
                    closed: value.is_closed(),
                }),
                EntityType::Polyline(value) => Some(Entity2DGeometry::Polyline {
                    points: value
                        .vertices()
                        .map(|vertex| point2(vertex.location.x, vertex.location.y))
                        .collect(),
                    closed: value.is_closed(),
                }),
                EntityType::Text(value) => Some(Entity2DGeometry::Text {
                    origin: point2(value.location.x, value.location.y),
                    value: normalize_cad_text(&value.value),
                    height: value.text_height,
                    rotation: value.rotation.to_radians(),
                }),
                EntityType::MText(value) => Some(Entity2DGeometry::Text {
                    origin: point2(value.insertion_point.x, value.insertion_point.y),
                    value: normalize_cad_text(&value.text),
                    height: value.initial_text_height,
                    rotation: value.rotation_angle.to_radians(),
                }),
                _ => None,
            };
            if let Some(geometry) = geometry {
                entities.push(Entity2D {
                    id: index as u64 + 1,
                    layer_id,
                    color_argb,
                    geometry,
                });
            } else {
                unsupported += 1;
            }
        }

        let mut scene = Scene2D {
            layers,
            entities,
            bounds: None,
        };
        scene.recompute_bounds();
        let mut diagnostics = Vec::new();
        if unsupported > 0 {
            diagnostics.push(FormatDiagnostic {
                code: "dxf.unsupported_entities".to_owned(),
                message: format!(
                    "{unsupported} entities are preserved by the parser but not rendered yet"
                ),
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
                units: None,
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

fn point2(x: f64, y: f64) -> Point2 {
    Point2::new(x, y)
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
    match index {
        1 => 0xffff4d4f,
        2 => 0xffffd666,
        3 => 0xff52c41a,
        4 => 0xff36cfc9,
        5 => 0xff4096ff,
        6 => 0xffb37feb,
        7 => 0xffe5e7eb,
        8 => 0xff8c8c8c,
        9 => 0xffbfbfbf,
        _ => 0xffe5e7eb,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
