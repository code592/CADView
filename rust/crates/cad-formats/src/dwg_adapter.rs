use crate::text_normalization::normalize_cad_text;
use acadrust::{
    entities::{EntityCommon, EntityType as AcadEntity},
    io::dwg::DwgReadOptions,
    CadDocument, Color as AcadColor, DwgReader,
};
use cad_core::{
    fingerprint, fingerprint_path, CadError, CancellationToken, DiagnosticSeverity,
    DocumentMetadata, Entity2D, Entity2DGeometry, FormatAdapter, FormatCapabilities,
    FormatDiagnostic, FormatId, Layer, OpenedDocument, Point2, Scene2D, SceneDocument, SceneKind,
    SceneSink, SupportLevel,
};
use std::{
    collections::{BTreeMap, HashSet},
    io::Cursor,
    path::Path,
};

const MAX_RENDER_ENTITIES: usize = 5_000_000;
const MAX_BLOCK_DEPTH: usize = 64;

pub struct DwgAdapter;

impl FormatAdapter for DwgAdapter {
    fn capabilities(&self) -> FormatCapabilities {
        FormatCapabilities {
            format: FormatId::Dwg,
            display_name: "AutoCAD Drawing".to_owned(),
            extensions: vec!["dwg".to_owned()],
            scene_kind: SceneKind::TwoD,
            support_level: SupportLevel::Beta,
            available: true,
            can_stream: false,
            can_measure: true,
            can_select_topology: false,
            note: Some(
                "acadrust 0.4.1 reads R13-R2018+ DWG; production status still requires the licensed corpus"
                    .to_owned(),
            ),
        }
    }

    fn probe(&self, header: &[u8], path: Option<&Path>) -> u8 {
        if header.starts_with(b"AC10") {
            100
        } else if path
            .and_then(Path::extension)
            .and_then(|value| value.to_str())
            .is_some_and(|value| value.eq_ignore_ascii_case("dwg"))
        {
            35
        } else {
            0
        }
    }

    fn open(
        &self,
        bytes: &[u8],
        display_name: &str,
        _source_path: Option<&Path>,
        cancel: &CancellationToken,
        sink: Option<&mut dyn SceneSink>,
    ) -> Result<OpenedDocument, CadError> {
        cancel.check()?;
        if !bytes.starts_with(b"AC10") {
            return Err(CadError::InvalidDocument(
                "DWG version signature is missing".to_owned(),
            ));
        }
        let mut strict_reader =
            DwgReader::from_stream_with_options(Cursor::new(bytes), DwgReadOptions::default());
        let (drawing, strict_failure) = match strict_reader.read() {
            Ok(drawing) => (drawing, None),
            Err(strict_error) => {
                cancel.check()?;
                let mut recovery_reader = DwgReader::from_stream_with_options(
                    Cursor::new(bytes),
                    DwgReadOptions::failsafe(),
                );
                let drawing = recovery_reader.read().map_err(|recovery_error| {
                    CadError::InvalidDocument(format!(
                        "DWG parse failed: {strict_error}; recovery failed: {recovery_error}"
                    ))
                })?;
                (drawing, Some(strict_error.to_string()))
            }
        };
        build_document(
            drawing,
            strict_failure,
            display_name,
            fingerprint(bytes),
            bytes.len() as u64,
            cancel,
            sink,
        )
    }

    fn open_path(
        &self,
        path: &Path,
        display_name: &str,
        cancel: &CancellationToken,
        sink: Option<&mut dyn SceneSink>,
    ) -> Result<OpenedDocument, CadError> {
        cancel.check()?;
        let byte_length = std::fs::metadata(path)?.len();
        let mut strict_reader = DwgReader::from_file_with_options(path, DwgReadOptions::default())
            .map_err(|error| CadError::InvalidDocument(error.to_string()))?;
        let (drawing, strict_failure) = match strict_reader.read() {
            Ok(drawing) => (drawing, None),
            Err(strict_error) => {
                cancel.check()?;
                let mut recovery_reader =
                    DwgReader::from_file_with_options(path, DwgReadOptions::failsafe())
                        .map_err(|error| CadError::InvalidDocument(error.to_string()))?;
                let drawing = recovery_reader.read().map_err(|recovery_error| {
                    CadError::InvalidDocument(format!(
                        "DWG parse failed: {strict_error}; recovery failed: {recovery_error}"
                    ))
                })?;
                (drawing, Some(strict_error.to_string()))
            }
        };
        cancel.check()?;
        build_document(
            drawing,
            strict_failure,
            display_name,
            fingerprint_path(path)?,
            byte_length,
            cancel,
            sink,
        )
    }
}

fn build_document(
    drawing: CadDocument,
    strict_failure: Option<String>,
    display_name: &str,
    source_fingerprint: String,
    byte_length: u64,
    cancel: &CancellationToken,
    mut sink: Option<&mut dyn SceneSink>,
) -> Result<OpenedDocument, CadError> {
    cancel.check()?;
    let mut layer_ids = BTreeMap::new();
    let mut layer_colors = BTreeMap::new();
    let mut layers = Vec::new();
    for (index, source) in drawing.layers.iter().enumerate() {
        let id = index as u64 + 1;
        let color = acad_color(source.color, 0xffe5e7eb);
        layer_ids.insert(source.name.clone(), id);
        layer_colors.insert(source.name.clone(), color);
        layers.push(Layer {
            id,
            name: source.name.clone(),
            visible: !source.flags.off && !source.flags.frozen,
            color_argb: color,
        });
    }
    if layers.is_empty() {
        layer_ids.insert("0".to_owned(), 1);
        layer_colors.insert("0".to_owned(), 0xffe5e7eb);
        layers.push(Layer {
            id: 1,
            name: "0".to_owned(),
            visible: true,
            color_argb: 0xffe5e7eb,
        });
    }

    let roots = display_roots(&drawing);
    let root_count = roots.entities.len();
    let layout_name = roots.layout_name.clone();
    let used_fallback_layout = roots.used_fallback_layout;
    let mut normalizer = DwgNormalizer {
        drawing: &drawing,
        layer_ids: &layer_ids,
        layer_colors: &layer_colors,
        cancel,
        entities: Vec::new(),
        unsupported: 0,
        processed: 0,
        next_synthetic_id: 1,
        used_ids: HashSet::new(),
    };
    let mut block_stack = HashSet::new();
    for (index, source) in roots.entities.into_iter().enumerate() {
        if index % 1024 == 0 {
            cancel.check()?;
            if let Some(sink) = sink.as_deref_mut() {
                let denominator = root_count.max(1) as f32;
                sink.progress((index as f32 / denominator).min(0.9));
            }
        }
        normalizer.append(source, 0, &mut block_stack)?;
    }
    let entities = normalizer.entities;
    let unsupported = normalizer.unsupported;

    let mut scene = Scene2D {
        layers,
        entities,
        bounds: None,
    };
    scene.recompute_bounds();
    let mut diagnostics = drawing
        .notifications
        .iter()
        .take(100)
        .map(|notification| FormatDiagnostic {
            code: "dwg.parser_recovery".to_owned(),
            message: notification.to_string(),
            severity: DiagnosticSeverity::Warning,
            entity_id: None,
        })
        .collect::<Vec<_>>();
    if let Some(strict_failure) = strict_failure {
        diagnostics.push(FormatDiagnostic {
            code: "dwg.failsafe_recovery".to_owned(),
            message: format!(
                "Strict DWG parsing failed and the document was recovered: {strict_failure}"
            ),
            severity: DiagnosticSeverity::Warning,
            entity_id: None,
        });
    }
    if used_fallback_layout {
        diagnostics.push(FormatDiagnostic {
            code: "dwg.layout_fallback".to_owned(),
            message: format!(
                "Model space has no displayable root entities; opened layout {layout_name}"
            ),
            severity: DiagnosticSeverity::Info,
            entity_id: None,
        });
    }
    if unsupported > 0 {
        diagnostics.push(FormatDiagnostic {
            code: "dwg.unsupported_entities".to_owned(),
            message: format!(
                "{unsupported} entities are parsed but not normalized by the Beta 2D renderer"
            ),
            severity: DiagnosticSeverity::Warning,
            entity_id: None,
        });
    }
    if scene.entities.is_empty() {
        diagnostics.push(FormatDiagnostic {
            code: "dwg.no_displayable_geometry".to_owned(),
            message: "The DWG was parsed, but the selected model/layout contains no supported visible 2D geometry"
                .to_owned(),
            severity: DiagnosticSeverity::Error,
            entity_id: None,
        });
    }
    let document = OpenedDocument {
        metadata: DocumentMetadata {
            format: FormatId::Dwg,
            display_name: display_name.to_owned(),
            fingerprint: source_fingerprint,
            byte_length,
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

struct DisplayRoots<'a> {
    entities: Vec<&'a AcadEntity>,
    layout_name: String,
    used_fallback_layout: bool,
}

fn display_roots(drawing: &CadDocument) -> DisplayRoots<'_> {
    let model = drawing.block_records.get("*Model_Space");
    let mut entities = model.map_or_else(Vec::new, |record| {
        record
            .entity_handles
            .iter()
            .filter_map(|handle| drawing.get_entity(*handle))
            .collect()
    });
    if !entities.is_empty() {
        return DisplayRoots {
            entities,
            layout_name: "Model".to_owned(),
            used_fallback_layout: false,
        };
    }

    if let Some(layout) = drawing
        .block_records
        .iter()
        .filter(|record| record.is_paper_space())
        .find(|record| !record.entity_handles.is_empty())
    {
        entities = layout
            .entity_handles
            .iter()
            .filter_map(|handle| drawing.get_entity(*handle))
            .collect();
        if !entities.is_empty() {
            return DisplayRoots {
                entities,
                layout_name: layout.name.clone(),
                used_fallback_layout: true,
            };
        }
    }

    // Some damaged files recovered in failsafe mode have incomplete owner
    // tables. Falling back to ownerless/model-space entities is safer than
    // reporting a successful but blank document.
    let model_handle = drawing.header.model_space_block_handle;
    entities = drawing
        .entities()
        .filter(|entity| {
            let owner = entity.common().owner_handle;
            owner.is_null() || owner == model_handle
        })
        .collect();
    DisplayRoots {
        entities,
        layout_name: "Model".to_owned(),
        used_fallback_layout: false,
    }
}

struct DwgNormalizer<'a> {
    drawing: &'a CadDocument,
    layer_ids: &'a BTreeMap<String, u64>,
    layer_colors: &'a BTreeMap<String, u32>,
    cancel: &'a CancellationToken,
    entities: Vec<Entity2D>,
    unsupported: u64,
    processed: usize,
    next_synthetic_id: u64,
    used_ids: HashSet<u64>,
}

impl DwgNormalizer<'_> {
    fn append(
        &mut self,
        source: &AcadEntity,
        depth: usize,
        block_stack: &mut HashSet<String>,
    ) -> Result<(), CadError> {
        if depth > MAX_BLOCK_DEPTH {
            return Err(CadError::ResourceLimit(format!(
                "DWG nested block depth exceeds {MAX_BLOCK_DEPTH}"
            )));
        }
        self.processed += 1;
        if self.processed > MAX_RENDER_ENTITIES {
            return Err(CadError::ResourceLimit(format!(
                "DWG rendered entity count exceeds {MAX_RENDER_ENTITIES}"
            )));
        }
        if self.processed % 4096 == 0 {
            self.cancel.check()?;
        }
        if source.common().invisible {
            return Ok(());
        }

        if let AcadEntity::Insert(insert) = source {
            if !block_stack.insert(insert.block_name.clone()) {
                self.unsupported += 1;
                return Ok(());
            }
            let exploded = insert.explode_from_document(self.drawing);
            for child in &exploded {
                self.append(child, depth + 1, block_stack)?;
            }
            // Attribute instances carry the user-visible values and are not
            // returned by Insert::explode_from_document.
            for attribute in &insert.attributes {
                self.push_geometry(
                    &attribute.common,
                    Entity2DGeometry::Text {
                        origin: point(attribute.insertion_point.x, attribute.insertion_point.y),
                        value: normalize_cad_text(&attribute.value),
                        height: attribute.height.abs(),
                        rotation: attribute.rotation,
                    },
                );
            }
            block_stack.remove(&insert.block_name);
            if exploded.is_empty() && insert.attributes.is_empty() {
                self.unsupported += 1;
            }
            return Ok(());
        }

        if let Some(geometry) = normalize_entity(source) {
            self.push_geometry(source.common(), geometry);
            return Ok(());
        }

        let exploded = source.explode();
        if exploded.is_empty() {
            self.unsupported += 1;
            return Ok(());
        }
        for child in &exploded {
            self.append(child, depth + 1, block_stack)?;
        }
        Ok(())
    }

    fn push_geometry(&mut self, common: &EntityCommon, geometry: Entity2DGeometry) {
        if !geometry_is_finite(&geometry) {
            self.unsupported += 1;
            return;
        }
        let layer_id = *self.layer_ids.get(&common.layer).unwrap_or(&1);
        let layer_color = *self.layer_colors.get(&common.layer).unwrap_or(&0xffe5e7eb);
        let source_id = common.handle.value();
        let id = if source_id == 0 || !self.used_ids.insert(source_id) {
            let id = self.next_synthetic_id;
            self.next_synthetic_id += 1;
            // Put synthetic IDs above the range used by ordinary DWG handles.
            let synthetic = u64::MAX / 2 + id;
            self.used_ids.insert(synthetic);
            synthetic
        } else {
            source_id
        };
        self.entities.push(Entity2D {
            id,
            layer_id,
            color_argb: acad_color(common.color, layer_color),
            geometry,
        });
    }
}

fn geometry_is_finite(geometry: &Entity2DGeometry) -> bool {
    let point_is_finite = |value: &Point2| value.x.is_finite() && value.y.is_finite();
    match geometry {
        Entity2DGeometry::Point { position } => point_is_finite(position),
        Entity2DGeometry::Line { start, end } => point_is_finite(start) && point_is_finite(end),
        Entity2DGeometry::Polyline { points, .. } => {
            !points.is_empty() && points.iter().all(point_is_finite)
        }
        Entity2DGeometry::Circle { center, radius }
        | Entity2DGeometry::Arc { center, radius, .. } => {
            point_is_finite(center) && radius.is_finite() && *radius > 0.0
        }
        Entity2DGeometry::Text {
            origin,
            height,
            rotation,
            ..
        } => point_is_finite(origin) && height.is_finite() && rotation.is_finite(),
    }
}

fn normalize_entity(source: &AcadEntity) -> Option<Entity2DGeometry> {
    match source {
        AcadEntity::Point(value) => Some(Entity2DGeometry::Point {
            position: point(value.location.x, value.location.y),
        }),
        AcadEntity::Line(value) => Some(Entity2DGeometry::Line {
            start: point(value.start.x, value.start.y),
            end: point(value.end.x, value.end.y),
        }),
        AcadEntity::Circle(value) => Some(Entity2DGeometry::Circle {
            center: point(value.center.x, value.center.y),
            radius: value.radius.abs(),
        }),
        AcadEntity::Arc(value) => Some(Entity2DGeometry::Arc {
            center: point(value.center.x, value.center.y),
            radius: value.radius.abs(),
            start_angle: value.start_angle,
            end_angle: value.end_angle,
        }),
        AcadEntity::Ellipse(value) => {
            let start = value.start_parameter;
            let sweep = (value.end_parameter - start).rem_euclid(std::f64::consts::TAU);
            let sweep = if sweep.abs() < 1e-9 {
                std::f64::consts::TAU
            } else {
                sweep
            };
            let major = value.major_axis;
            let minor_x = -major.y * value.minor_axis_ratio;
            let minor_y = major.x * value.minor_axis_ratio;
            Some(Entity2DGeometry::Polyline {
                points: (0..=64)
                    .map(|index| {
                        let parameter = start + sweep * index as f64 / 64.0;
                        point(
                            value.center.x + major.x * parameter.cos() + minor_x * parameter.sin(),
                            value.center.y + major.y * parameter.cos() + minor_y * parameter.sin(),
                        )
                    })
                    .collect(),
                closed: value.is_full(),
            })
        }
        AcadEntity::LwPolyline(value) => Some(Entity2DGeometry::Polyline {
            points: value
                .vertices
                .iter()
                .map(|vertex| point(vertex.location.x, vertex.location.y))
                .collect(),
            closed: value.is_closed,
        }),
        AcadEntity::Polyline(value) => Some(Entity2DGeometry::Polyline {
            points: value
                .vertices
                .iter()
                .map(|vertex| point(vertex.location.x, vertex.location.y))
                .collect(),
            closed: value.is_closed(),
        }),
        AcadEntity::Polyline2D(value) => Some(Entity2DGeometry::Polyline {
            points: value
                .vertices
                .iter()
                .map(|vertex| point(vertex.location.x, vertex.location.y))
                .collect(),
            closed: value.is_closed(),
        }),
        AcadEntity::Text(value) => Some(Entity2DGeometry::Text {
            origin: point(value.insertion_point.x, value.insertion_point.y),
            value: normalize_cad_text(&value.value),
            height: value.height.abs(),
            rotation: value.rotation,
        }),
        AcadEntity::MText(value) => Some(Entity2DGeometry::Text {
            origin: point(value.insertion_point.x, value.insertion_point.y),
            value: normalize_cad_text(&value.value),
            height: value.height.abs(),
            rotation: value.rotation,
        }),
        _ => None,
    }
}

fn point(x: f64, y: f64) -> Point2 {
    Point2::new(x, y)
}

fn acad_color(color: AcadColor, fallback: u32) -> u32 {
    color.rgb().map_or(fallback, |(red, green, blue)| {
        0xff000000 | ((red as u32) << 16) | ((green as u32) << 8) | blue as u32
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use acadrust::{
        entities::Insert, tables::BlockRecord, CadDocument, DwgWriter, EntityType, Line, Vector3,
    };

    #[test]
    fn detects_dwg_magic_without_extension() {
        assert_eq!(DwgAdapter.probe(b"AC1032", None), 100);
    }

    #[test]
    fn opens_generated_dwg_geometry_end_to_end() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("line.dwg");
        let mut source = CadDocument::new();
        source
            .add_entity(EntityType::Line(Line::from_coords(
                1.0, 2.0, 0.0, 4.0, 6.0, 0.0,
            )))
            .unwrap();
        DwgWriter::write_to_file(&path, &source).unwrap();
        let bytes = std::fs::read(&path).unwrap();

        let opened = DwgAdapter
            .open(
                &bytes,
                "line.dwg",
                Some(&path),
                &CancellationToken::default(),
                None,
            )
            .unwrap();

        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected a 2D scene");
        };
        assert!(scene
            .entities
            .iter()
            .any(|entity| matches!(entity.geometry, Entity2DGeometry::Line { .. })));
    }

    #[test]
    fn renders_model_space_inserted_block_in_world_coordinates() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("insert.dwg");
        let mut source = CadDocument::new();
        let mut block = BlockRecord::new("PART");
        block.handle = source.allocate_handle();
        let block_handle = block.handle;
        source.block_records.add(block).unwrap();

        let mut line = Line::from_coords(1.0, 2.0, 0.0, 4.0, 6.0, 0.0);
        line.common.owner_handle = block_handle;
        source.add_entity(EntityType::Line(line)).unwrap();
        source
            .add_entity(EntityType::Insert(Insert::new(
                "PART",
                Vector3::new(100.0, 200.0, 0.0),
            )))
            .unwrap();
        DwgWriter::write_to_file(&path, &source).unwrap();
        let bytes = std::fs::read(&path).unwrap();

        let opened = DwgAdapter
            .open(
                &bytes,
                "insert.dwg",
                Some(&path),
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected a 2D scene");
        };
        let line = scene
            .entities
            .iter()
            .find_map(|entity| match entity.geometry {
                Entity2DGeometry::Line { start, end } => Some((start, end)),
                _ => None,
            });
        let (start, end) = line.expect("inserted block line must be visible");
        assert!((start.x - 101.0).abs() < 1e-6);
        assert!((start.y - 202.0).abs() < 1e-6);
        assert!((end.x - 104.0).abs() < 1e-6);
        assert!((end.y - 206.0).abs() < 1e-6);
    }
}
