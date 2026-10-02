use crate::affine2d::{transform_geometry, Affine2};
use crate::curves;
use crate::mleader;
use crate::ocs_curves::{self, ocs_entity_circle_or_arc};
use crate::text_coordinates::{mtext_axes, ocs_axes, plane, Axes3};
use crate::text_normalization::{
    append_text_diagnostics, mtext_background, mtext_columns, mtext_line_spacing, parse_mtext,
    parse_single_line_text, SourceMTextColumns,
};
use crate::units::autocad_unit_id;
use acadrust::{
    entities::{
        AttachmentPoint, Dimension, EntityCommon, EntityType as AcadEntity,
        TextHorizontalAlignment, TextVerticalAlignment,
    },
    io::dwg::DwgReadOptions,
    tables::BlockRecord,
    types::{Matrix3, Matrix4, Transform},
    CadDocument, Color as AcadColor, DwgReader, Handle, Vector3,
};
use cad_core::{
    fingerprint, fingerprint_path, CadError, CancellationToken, DiagnosticSeverity,
    DocumentMetadata, Entity2D, Entity2DGeometry, FormatAdapter, FormatCapabilities,
    FormatDiagnostic, FormatId, Layer, OpenedDocument, Point2, Scene2D, SceneDocument, SceneKind,
    SceneSink, SupportLevel, TextHorizontalAlignment2D, TextVerticalAlignment2D,
};
use std::{
    collections::{BTreeMap, HashSet},
    io::Cursor,
    path::Path,
};

const MAX_RENDER_ENTITIES: usize = 5_000_000;
const MAX_BLOCK_DEPTH: usize = 64;
// Scene IDs cross a JSON boundary before the native texture renderer replaces
// the preview path. Keep them exactly representable by Dart/JavaScript numbers.
const MAX_JSON_SAFE_ENTITY_ID: u64 = (1_u64 << 53) - 1;

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
    let units = autocad_unit_id(drawing.header.insertion_units).map(str::to_owned);
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
        unsupported_kinds: BTreeMap::new(),
        processed: 0,
        next_synthetic_id: 1,
        used_ids: HashSet::new(),
        block_colors: Vec::new(),
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
    let unsupported_kinds = normalizer.unsupported_kinds;

    let mut scene = Scene2D {
        layers,
        entities,
        bounds: None,
    };
    recompute_visible_bounds(&mut scene);
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
        let details = unsupported_kinds
            .iter()
            .map(|(kind, count)| format!("{kind}: {count}"))
            .collect::<Vec<_>>()
            .join(", ");
        diagnostics.push(FormatDiagnostic {
            code: "dwg.unsupported_entities".to_owned(),
            message: format!(
                "{unsupported} entities are parsed but not normalized by the Beta 2D renderer ({details})"
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
    append_text_diagnostics(&scene, &mut diagnostics);
    let document = OpenedDocument {
        metadata: DocumentMetadata {
            format: FormatId::Dwg,
            display_name: display_name.to_owned(),
            fingerprint: source_fingerprint,
            byte_length,
            units,
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
        block_record_entities(
            drawing,
            record,
            Some(drawing.header.model_space_block_handle),
        )
    });
    if !entities.is_empty() {
        return DisplayRoots {
            entities,
            layout_name: "Model".to_owned(),
            used_fallback_layout: false,
        };
    }

    for layout in drawing
        .block_records
        .iter()
        .filter(|record| record.is_paper_space())
    {
        entities = block_record_entities(drawing, layout, None);
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

/// DWG block-record handle lists are an acceleration structure, not the sole
/// source of truth. Some real-world and failsafe-recovered files contain a
/// partially populated list while every entity still has the correct owner.
/// Unioning both sources prevents a valid model or block from being truncated.
fn block_record_entities<'a>(
    drawing: &'a CadDocument,
    record: &BlockRecord,
    additional_owner: Option<Handle>,
) -> Vec<&'a AcadEntity> {
    let mut entities = Vec::new();
    let mut seen = HashSet::new();
    for handle in &record.entity_handles {
        if let Some(entity) = drawing.get_entity(*handle) {
            push_unique_entity(&mut entities, &mut seen, entity);
        }
    }
    for entity in drawing.entities() {
        let owner = entity.common().owner_handle;
        let owned_by_record = !record.handle.is_null() && owner == record.handle;
        let owned_by_alias = additional_owner
            .filter(|handle| !handle.is_null())
            .is_some_and(|handle| owner == handle);
        if owned_by_record || owned_by_alias {
            push_unique_entity(&mut entities, &mut seen, entity);
        }
    }
    entities
}

fn push_unique_entity<'a>(
    entities: &mut Vec<&'a AcadEntity>,
    seen: &mut HashSet<usize>,
    entity: &'a AcadEntity,
) {
    let identity = entity as *const AcadEntity as usize;
    if seen.insert(identity) {
        entities.push(entity);
    }
}

fn recompute_visible_bounds(scene: &mut Scene2D) {
    let visible_layers = scene
        .layers
        .iter()
        .filter(|layer| layer.visible)
        .map(|layer| layer.id)
        .collect::<HashSet<_>>();
    scene.bounds = scene
        .entities
        .iter()
        .filter(|entity| visible_layers.contains(&entity.layer_id))
        .filter_map(Entity2D::bounds)
        .fold(None, |current, next| {
            Some(match current {
                None => next,
                Some(mut bounds) => {
                    bounds.include(next.min);
                    bounds.include(next.max);
                    bounds
                }
            })
        });
}

struct DwgNormalizer<'a> {
    drawing: &'a CadDocument,
    layer_ids: &'a BTreeMap<String, u64>,
    layer_colors: &'a BTreeMap<String, u32>,
    cancel: &'a CancellationToken,
    entities: Vec<Entity2D>,
    unsupported: u64,
    unsupported_kinds: BTreeMap<&'static str, u64>,
    processed: usize,
    next_synthetic_id: u64,
    used_ids: HashSet<u64>,
    block_colors: Vec<AcadColor>,
}

impl DwgNormalizer<'_> {
    fn append(
        &mut self,
        source: &AcadEntity,
        depth: usize,
        block_stack: &mut HashSet<String>,
    ) -> Result<(), CadError> {
        self.append_in_frame(source, source, &Transform::identity(), depth, block_stack)
    }

    // Keep the original text and its complete 3D instance frame beside the
    // legacy exploded geometry. Reconstructing a nested INSERT from lengths
    // and angles loses shear; projecting before composition also loses Z.
    fn append_in_frame(
        &mut self,
        source: &AcadEntity,
        original: &AcadEntity,
        text_frame: &Transform,
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
                self.mark_unsupported("INSERT_CYCLE");
                return Ok(());
            }
            let AcadEntity::Insert(original_insert) = original else {
                return Err(CadError::InvalidDocument(
                    "DWG INSERT source identity mismatch".to_owned(),
                ));
            };
            self.block_colors.push(insert.common.color);
            let record = self.drawing.block_records.get(&original_insert.block_name);
            let block_entities = record.map_or_else(Vec::new, |record| {
                block_record_entities(self.drawing, record, None)
            });
            // Constant ATTDEF values belong to the block definition. Unlike
            // ordinary ATTRIB, their coordinates need the complete INSERT frame.
            // Nonconstant definitions are prompts, not additional visible text.
            let constants = block_entities
                .iter()
                .copied()
                .filter_map(|entity| match entity {
                    AcadEntity::AttributeDefinition(definition)
                        if definition.flags.constant
                            && !definition.flags.invisible
                            && !definition.common.invisible =>
                    {
                        Some(definition)
                    }
                    _ => None,
                })
                .collect::<Vec<_>>();
            let original_children = block_entities
                .into_iter()
                .filter(|entity| {
                    !matches!(
                        entity,
                        AcadEntity::Block(_)
                            | AcadEntity::BlockEnd(_)
                            | AcadEntity::AttributeDefinition(_)
                    )
                })
                .collect::<Vec<_>>();
            let cells = if insert.is_minsert() {
                insert.instance_count()
            } else {
                1
            };
            let expected = original_children.len().checked_mul(cells).ok_or_else(|| {
                CadError::ResourceLimit("DWG block instance count overflow".to_owned())
            })?;
            let with_attributes = original_children
                .len()
                .checked_add(original_insert.attributes.len())
                .and_then(|count| count.checked_add(constants.len()))
                .and_then(|count| count.checked_mul(cells))
                .ok_or_else(|| {
                    CadError::ResourceLimit("DWG attribute instance count overflow".to_owned())
                })?;
            if with_attributes > MAX_RENDER_ENTITIES.saturating_sub(self.processed) {
                return Err(CadError::ResourceLimit(
                    "DWG block expansion exceeds entity limit".to_owned(),
                ));
            }
            let exploded = record
                .filter(|_| !original_children.is_empty())
                .map_or_else(Vec::new, |record| {
                    self.explode_insert(insert, record, &original_children)
                });
            if exploded.len() != expected {
                return Err(CadError::InvalidDocument(
                    "DWG block expansion lost source correspondence".to_owned(),
                ));
            }
            if !original_children.is_empty() {
                for (cell, children) in exploded.chunks(original_children.len()).enumerate() {
                    let local =
                        insert_text_frame(original_insert, record.unwrap().base_point, cell);
                    let frame = text_frame.compose(&local);
                    for (child, original_child) in children.iter().zip(&original_children) {
                        self.append_in_frame(
                            child,
                            original_child,
                            &frame,
                            depth + 1,
                            block_stack,
                        )?;
                    }
                }
            }
            for cell in 0..cells {
                if constants.is_empty() {
                    break;
                }
                let local = insert_text_frame(original_insert, record.unwrap().base_point, cell);
                let frame = text_frame.compose(&local);
                for definition in &constants {
                    self.processed += 1;
                    if self.processed % 4096 == 0 {
                        self.cancel.check()?;
                    }
                    let attribute =
                        acadrust::entities::AttributeEntity::from_definition(definition, None);
                    let Some(geometry) = normalize_attribute(&attribute, self.drawing, &frame)
                    else {
                        self.mark_unsupported("ATTDEF_INVALID_TEXT_PLANE");
                        continue;
                    };
                    let mut common = definition.common.clone();
                    if common.layer == "0" {
                        common.layer.clone_from(&insert.common.layer);
                    }
                    if common.color == AcadColor::ByBlock {
                        common.color = insert.common.color;
                    }
                    self.push_geometry(&common, geometry, 0.0, false);
                }
            }
            // ATTRIB positions are already expressed in the containing space,
            // unlike the block definition. Apply only the enclosing frame and
            // each MINSERT grid offset, not the INSERT's own scale/translation.
            if insert.attributes.len() != original_insert.attributes.len() {
                return Err(CadError::InvalidDocument(
                    "DWG attribute source identity mismatch".to_owned(),
                ));
            }
            for (attribute, original_attribute) in
                insert.attributes.iter().zip(&original_insert.attributes)
            {
                if original_attribute.common.invisible || original_attribute.flags.invisible {
                    continue;
                }
                let Some(geometry) =
                    normalize_attribute(original_attribute, self.drawing, text_frame)
                else {
                    self.mark_unsupported("ATTRIB_INVALID_TEXT_PLANE");
                    continue;
                };
                let mut common = attribute.common.clone();
                if common.layer == "0" {
                    common.layer.clone_from(&insert.common.layer);
                }
                if common.color == AcadColor::ByBlock {
                    common.color = insert.common.color;
                }
                for cell in 0..cells {
                    self.processed += 1;
                    if self.processed % 4096 == 0 {
                        self.cancel.check()?;
                    }
                    let grid = Matrix3::arbitrary_axis(original_insert.normal)
                        * insert_grid_offset(original_insert, cell);
                    let offset = text_frame.apply_rotation(grid);
                    let mut instance = geometry.clone();
                    if let Entity2DGeometry::Text { origin, .. } = &mut instance {
                        origin.x += offset.x;
                        origin.y += offset.y;
                    }
                    self.push_geometry(&common, instance, 0.0, false);
                }
            }
            block_stack.remove(&insert.block_name);
            self.block_colors.pop();
            if exploded.is_empty() && insert.attributes.is_empty() && constants.is_empty() {
                self.mark_unsupported("INSERT_EMPTY");
            }
            return Ok(());
        }

        if let (AcadEntity::MultiLeader(_), AcadEntity::MultiLeader(leader)) = (source, original) {
            return self.append_mleader(leader, text_frame, depth, block_stack);
        }
        if let (AcadEntity::Table(_), AcadEntity::Table(table)) = (source, original) {
            // ACAD_TABLE is drawn by its anonymous `*T` block, inserted at the
            // table origin with its X axis along the horizontal direction.
            let Some(name) = table
                .block_record_handle
                .and_then(|handle| self.block_name(handle))
            else {
                self.mark_unsupported("TABLE_GRAPHICS_MISSING");
                return Ok(());
            };
            let normal = [table.normal.x, table.normal.y, table.normal.z];
            let direction = [
                table.horizontal_direction.x,
                table.horizontal_direction.y,
                table.horizontal_direction.z,
            ];
            let mut insert = acadrust::entities::Insert::new(name, table.insertion_point)
                .with_rotation(mleader::table_rotation(
                    direction,
                    ocs_curves::ocs_axes_or_world(normal),
                ))
                .with_normal(table.normal);
            insert.common = table.common.clone();
            return self.append_synthetic_insert(insert, text_frame, depth, block_stack);
        }

        if let AcadEntity::Dimension(dimension) = source {
            if self.append_dimension_block(dimension, text_frame, depth, block_stack)? {
                return Ok(());
            }
            // acadrust 0.4.1's generic Dimension::explode implementation is a
            // deliberately simplified fallback. For linear dimensions it
            // connects both measured points directly to the dimension-line
            // definition point, producing the large diagonal triangles seen
            // in real drawings. A missing anonymous dimension block is safer
            // to diagnose than to render as geometry that is known to be
            // incorrect.
            self.mark_unsupported("DIMENSION_GRAPHICS_MISSING");
            return Ok(());
        }

        let frame = affine_from_transform(text_frame);
        let geometry = if matches!(original, AcadEntity::Text(_) | AcadEntity::MText(_)) {
            normalize_entity_in_frame(original, self.drawing, text_frame)
        } else if has_circular_arcs(original) && !frame.is_similarity() {
            // ARC, CIRCLE and bulges describe circular arcs only. Under a
            // non-uniform block scale they become elliptical (also when a
            // HATCH boundary is exploded into them), so normalize in block
            // space and map the outline exactly.
            normalize_entity(original, self.drawing)
                .and_then(|geometry| transform_geometry(geometry, &frame))
        } else {
            normalize_entity(source, self.drawing)
        };
        if let Some(geometry) = geometry {
            self.push_geometry(
                source.common(),
                geometry,
                entity_stroke_width(source),
                matches!(source, AcadEntity::Solid(_)),
            );
            return Ok(());
        }

        let exploded = source.explode();
        if exploded.is_empty() {
            self.mark_unsupported(source.as_entity().entity_type());
            return Ok(());
        }
        let original_children = original.explode();
        if original_children.len() == exploded.len() {
            for (child, original_child) in exploded.iter().zip(&original_children) {
                self.append_in_frame(child, original_child, text_frame, depth + 1, block_stack)?;
            }
        } else {
            self.mark_unsupported("COMPOSITE_TEXT_TRANSFORM_FALLBACK");
            for child in &exploded {
                self.append(child, depth + 1, block_stack)?;
            }
        }
        Ok(())
    }

    /// Render the anonymous `*D…` block stored by CAD applications for a
    /// DIMENSION. It is the authoritative display representation and already
    /// contains the exact extension lines, dimension line, arrowheads and
    /// formatted text. POINT entities in that block are definition helpers,
    /// not visible marks, and must never enter the display scene.
    fn append_dimension_block(
        &mut self,
        dimension: &Dimension,
        text_frame: &Transform,
        depth: usize,
        block_stack: &mut HashSet<String>,
    ) -> Result<bool, CadError> {
        let base = dimension.base();
        let block_name = base.block_name.trim();
        if block_name.is_empty() {
            return Ok(false);
        }
        let Some(record) = self.drawing.block_records.get(block_name) else {
            return Ok(false);
        };
        if !block_stack.insert(block_name.to_owned()) {
            self.mark_unsupported("DIMENSION_BLOCK_CYCLE");
            return Ok(false);
        }

        let before = self.entities.len();
        self.block_colors.push(base.common.color);
        let children = block_record_entities(self.drawing, record, None);
        for source in children {
            // Anonymous dimension blocks commonly retain three POINT entities
            // for grip/edit locations. Rendering those helper points creates
            // spurious dots and can also enlarge the scene bounds.
            if matches!(source, AcadEntity::Point(_)) {
                continue;
            }
            let mut child = source.clone();
            if !text_frame.is_identity() {
                child.as_entity_mut().apply_transform(text_frame);
            }
            // Layer 0 and ByBlock properties inherit from the DIMENSION, just
            // as they do for an INSERT. Without this, dimensions on a hidden
            // layer could remain visible and their colors would be wrong.
            let common = child.common_mut();
            if common.layer == "0" && base.common.layer != "0" {
                common.layer.clone_from(&base.common.layer);
            }
            if common.color == AcadColor::ByBlock {
                common.color = base.common.color;
            }
            self.append_in_frame(&child, source, text_frame, depth + 1, block_stack)?;
        }
        block_stack.remove(block_name);
        self.block_colors.pop();
        Ok(self.entities.len() > before)
    }

    fn explode_insert(
        &self,
        insert: &acadrust::entities::Insert,
        record: &BlockRecord,
        original_children: &[&AcadEntity],
    ) -> Vec<AcadEntity> {
        // Reuse the root list used for source correspondence. Do not rescan all
        // drawing entities or transform excluded definitions for each INSERT.
        let mut block_entities = original_children
            .iter()
            .map(|entity| (*entity).clone())
            .collect::<Vec<_>>();
        let base = record.base_point;
        if base.x != 0.0 || base.y != 0.0 || base.z != 0.0 {
            let shift = Transform::from_translation(Vector3::new(-base.x, -base.y, -base.z));
            for entity in &mut block_entities {
                entity.as_entity_mut().apply_transform(&shift);
            }
        }
        insert.explode(&block_entities)
    }

    fn block_name(&self, handle: Handle) -> Option<String> {
        self.drawing
            .block_records
            .iter()
            .find(|record| record.handle == handle)
            .map(|record| record.name.clone())
    }

    /// Expands a block reference that has no INSERT of its own (table graphics,
    /// MULTILEADER block content) through the ordinary INSERT path.
    fn append_synthetic_insert(
        &mut self,
        original: acadrust::entities::Insert,
        frame: &Transform,
        depth: usize,
        block_stack: &mut HashSet<String>,
    ) -> Result<(), CadError> {
        let original = AcadEntity::Insert(original);
        let mut source = original.clone();
        if !frame.is_identity() {
            source.as_entity_mut().apply_transform(frame);
        }
        self.append_in_frame(&source, &original, frame, depth + 1, block_stack)
    }

    fn append_mleader(
        &mut self,
        leader: &acadrust::entities::MultiLeader,
        frame: &Transform,
        depth: usize,
        block_stack: &mut HashSet<String>,
    ) -> Result<(), CadError> {
        let model = mleader_model(leader);
        let arrowhead = mleader::arrowhead_kind(
            model
                .arrowhead_handle
                .and_then(|handle| self.block_name(Handle::from(handle)))
                .as_deref(),
        );
        let affine = affine_from_transform(frame);
        let line_common = part_common(&leader.common, leader.line_color);
        for (geometry, filled) in mleader::leader_geometry(&model, arrowhead) {
            match transform_geometry(geometry, &affine) {
                Some(geometry) => self.push_geometry(&line_common, geometry, 0.0, filled),
                None => self.mark_unsupported("DEGENERATE_TRANSFORM"),
            }
        }
        let context = &leader.context;
        if let Some(text) = &model.text {
            let direction = if text.direction.iter().all(|value| *value == 0.0) {
                Vector3::new(1.0, 0.0, 0.0)
            } else {
                context.text_direction
            };
            let style = text
                .style_handle
                .and_then(|handle| {
                    self.drawing
                        .text_styles
                        .iter()
                        .find(|style| style.handle == Handle::from(handle))
                })
                .map_or_else(|| "STANDARD".to_owned(), |style| style.name.clone());
            let paragraph = acadrust::entities::MText {
                common: part_common(&leader.common, context.text_color),
                value: text.value.clone(),
                insertion_point: context.text_location,
                height: text.height,
                rectangle_width: text.width,
                rotation: direction.y.atan2(direction.x),
                x_direction: Some(direction),
                normal: context.text_normal,
                style,
                attachment_point: match text.alignment {
                    2 => AttachmentPoint::TopCenter,
                    3 => AttachmentPoint::TopRight,
                    _ => AttachmentPoint::TopLeft,
                },
                line_spacing_factor: text.line_spacing_factor,
                ..acadrust::entities::MText::new()
            };
            let common = paragraph.common.clone();
            if let Some(geometry) =
                normalize_entity_in_frame(&AcadEntity::MText(paragraph), self.drawing, frame)
            {
                self.push_geometry(&common, geometry, 0.0, false);
            }
        }
        if let Some(block) = &model.block {
            let Some(name) = self.block_name(Handle::from(block.block_handle)) else {
                self.mark_unsupported("MULTILEADER_BLOCK_MISSING");
                return Ok(());
            };
            let mut insert = acadrust::entities::Insert::new(name, context.block_content_location)
                .with_scale(block.scale[0], block.scale[1], block.scale[2])
                .with_rotation(block.rotation)
                .with_normal(context.block_content_normal);
            insert.common = part_common(&leader.common, context.block_content_color);
            self.append_synthetic_insert(insert, frame, depth, block_stack)?;
        }
        Ok(())
    }

    fn push_geometry(
        &mut self,
        common: &EntityCommon,
        mut geometry: Entity2DGeometry,
        stroke_width: f64,
        filled: bool,
    ) {
        if !geometry_is_finite(&geometry) {
            self.mark_unsupported("NON_FINITE_GEOMETRY");
            return;
        }
        let layer_id = *self.layer_ids.get(&common.layer).unwrap_or(&1);
        let layer_color = *self.layer_colors.get(&common.layer).unwrap_or(&0xffe5e7eb);
        if let Entity2DGeometry::Text {
            background: Some(background),
            ..
        } = &mut geometry
        {
            use cad_core::MTextBackgroundColor2D as B;
            match background.color_mode {
                B::ByLayer => {
                    background.color_argb = layer_color;
                    background.color_mode = B::Explicit;
                }
                B::ByBlock => {
                    background.color_argb = acad_color(
                        self.block_colors
                            .last()
                            .copied()
                            .unwrap_or(AcadColor::ByLayer),
                        layer_color,
                    );
                    background.color_mode = B::Explicit;
                }
                _ => {}
            }
        }
        let source_id = common.handle.value();
        let id = if source_id != 0
            && source_id <= MAX_JSON_SAFE_ENTITY_ID
            && self.used_ids.insert(source_id)
        {
            source_id
        } else {
            // Allocate downwards from Number.MAX_SAFE_INTEGER. DWG handles are
            // normally small, so this avoids collisions while keeping the ID
            // an integer after serde_json -> Dart jsonDecode.
            loop {
                let synthetic = MAX_JSON_SAFE_ENTITY_ID - self.next_synthetic_id;
                self.next_synthetic_id += 1;
                if self.used_ids.insert(synthetic) {
                    break synthetic;
                }
            }
        };
        self.entities.push(Entity2D {
            id,
            layer_id,
            color_argb: acad_color(common.color, layer_color),
            stroke_width: if stroke_width.is_finite() {
                stroke_width.max(0.0)
            } else {
                0.0
            },
            filled,
            geometry,
        });
    }

    fn mark_unsupported(&mut self, kind: &'static str) {
        self.unsupported += 1;
        *self.unsupported_kinds.entry(kind).or_default() += 1;
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
            width_factor,
            oblique_angle,
            plane,
            ..
        } => {
            point_is_finite(origin)
                && height.is_finite()
                && rotation.is_finite()
                && width_factor.is_finite()
                && oblique_angle.is_finite()
                && plane
                    .as_ref()
                    .is_none_or(|p| [p.xx, p.xy, p.yx, p.yy].iter().all(|v| v.is_finite()))
        }
    }
}

fn axes_point(axes: Axes3, p: Vector3) -> Vector3 {
    Vector3::new(
        axes[0][0] * p.x + axes[1][0] * p.y + axes[2][0] * p.z,
        axes[0][1] * p.x + axes[1][1] * p.y + axes[2][1] * p.z,
        axes[0][2] * p.x + axes[1][2] * p.y + axes[2][2] * p.z,
    )
}

fn transformed_axes(axes: Axes3, transform: &Transform) -> Axes3 {
    axes.map(|axis| {
        let v = transform.apply_rotation(Vector3::new(axis[0], axis[1], axis[2]));
        [v.x, v.y, v.z]
    })
}

fn insert_grid_offset(insert: &acadrust::entities::Insert, cell: usize) -> Vector3 {
    if insert.is_minsert() {
        let col = cell % usize::from(insert.column_count);
        let row = cell / usize::from(insert.column_count);
        let x = col as f64 * insert.column_spacing;
        let y = row as f64 * insert.row_spacing;
        return Vector3::new(
            x * insert.rotation.cos() - y * insert.rotation.sin(),
            x * insert.rotation.sin() + y * insert.rotation.cos(),
            0.0,
        );
    }
    Vector3::ZERO
}

fn insert_text_frame(insert: &acadrust::entities::Insert, base: Vector3, cell: usize) -> Transform {
    let position = insert.insert_point + insert_grid_offset(insert, cell);
    let axes = Matrix4::from_matrix3(Matrix3::arbitrary_axis(insert.normal));
    let translation = Matrix4::translation(position.x, position.y, position.z);
    let rotation = Matrix4::rotation_z(insert.rotation);
    let scaling = Matrix4::scaling(insert.x_scale(), insert.y_scale(), insert.z_scale());
    Transform::from_matrix(axes * translation * rotation * scaling).compose(
        &Transform::from_translation(Vector3::new(-base.x, -base.y, -base.z)),
    )
}

fn normalize_entity(source: &AcadEntity, drawing: &CadDocument) -> Option<Entity2DGeometry> {
    normalize_entity_in_frame(source, drawing, &Transform::identity())
}

fn normalize_attribute(
    attribute: &acadrust::entities::AttributeEntity,
    drawing: &CadDocument,
    frame: &Transform,
) -> Option<Entity2DGeometry> {
    if let Some(paragraph) = &attribute.embedded_mtext {
        // The embedded paragraph is authoritative for content, WCS placement,
        // attachment, wrapping, spacing and style. The outer TEXT fields are a
        // legacy representation and must not overwrite it or transform it twice.
        return normalize_entity_in_frame(&AcadEntity::MText(paragraph.clone()), drawing, frame);
    }
    use acadrust::entities::attribute_definition::{
        HorizontalAlignment as H, VerticalAlignment as V,
    };
    let text = acadrust::entities::Text {
        insertion_point: attribute.insertion_point,
        alignment_point: Some(attribute.alignment_point),
        value: attribute.value.clone(),
        height: attribute.height,
        rotation: attribute.rotation,
        normal: attribute.normal,
        width_factor: attribute.width_factor,
        oblique_angle: attribute.oblique_angle,
        style: attribute.text_style.clone(),
        generation_flags: attribute.text_generation_flags,
        horizontal_alignment: match attribute.horizontal_alignment {
            H::Left => TextHorizontalAlignment::Left,
            H::Center => TextHorizontalAlignment::Center,
            H::Right => TextHorizontalAlignment::Right,
            H::Aligned => TextHorizontalAlignment::Aligned,
            H::Middle => TextHorizontalAlignment::Middle,
            H::Fit => TextHorizontalAlignment::Fit,
        },
        vertical_alignment: match attribute.vertical_alignment {
            V::Baseline => TextVerticalAlignment::Baseline,
            V::Bottom => TextVerticalAlignment::Bottom,
            V::Middle => TextVerticalAlignment::Middle,
            V::Top => TextVerticalAlignment::Top,
        },
        ..acadrust::entities::Text::new()
    };
    let mut geometry = normalize_entity_in_frame(&AcadEntity::Text(text), drawing, frame)?;
    if attribute.is_multiline {
        // Programmatic/legacy attributes may declare multiline without carrying
        // a paragraph. Keep a readable fallback and diagnose absent layout.
        let mut parsed = parse_mtext(&attribute.value, attribute.height.abs());
        parsed
            .warnings
            .push("Embedded multiline attribute layout is unavailable".to_owned());
        if let Entity2DGeometry::Text {
            value,
            text_runs,
            text_warnings,
            line_spacing,
            ..
        } = &mut geometry
        {
            *value = parsed.value;
            *text_runs = parsed.runs;
            *text_warnings = parsed.warnings;
            *line_spacing = Some(cad_core::MTextLineSpacing2D::default());
        }
    }
    Some(geometry)
}

fn normalize_entity_in_frame(
    source: &AcadEntity,
    drawing: &CadDocument,
    text_frame: &Transform,
) -> Option<Entity2DGeometry> {
    match source {
        AcadEntity::Point(value) => Some(Entity2DGeometry::Point {
            position: point(value.location.x, value.location.y),
        }),
        AcadEntity::Line(value) => Some(Entity2DGeometry::Line {
            start: point(value.start.x, value.start.y),
            end: point(value.end.x, value.end.y),
        }),
        AcadEntity::Solid(value) => {
            // SOLID corners are drawn 1-2-4-3 (a "Z" pick order); the fourth
            // equals the third for a triangle.
            let ocs = Matrix3::arbitrary_axis(value.normal);
            let mut corners = vec![value.first_corner, value.second_corner, value.fourth_corner];
            if value.fourth_corner != value.third_corner {
                corners.push(value.third_corner);
            }
            Some(Entity2DGeometry::Polyline {
                points: corners
                    .into_iter()
                    .map(|corner| {
                        let world = ocs * corner;
                        point(world.x, world.y)
                    })
                    .collect(),
                closed: true,
            })
        }
        // DWG CIRCLE/ARC centers and angles are OCS values. acadrust's INSERT
        // explosion also returns arcs in the (possibly flipped) OCS.
        AcadEntity::Circle(value) => Some(ocs_entity_circle_or_arc(
            [value.center.x, value.center.y, value.center.z],
            value.radius,
            [value.normal.x, value.normal.y, value.normal.z],
            None,
        )),
        AcadEntity::Arc(value) => Some(ocs_entity_circle_or_arc(
            [value.center.x, value.center.y, value.center.z],
            value.radius,
            [value.normal.x, value.normal.y, value.normal.z],
            Some((value.start_angle, value.end_angle)),
        )),
        AcadEntity::Ellipse(value) => {
            let (points, full) = curves::tessellate_ellipse(
                [value.center.x, value.center.y, value.center.z],
                [value.major_axis.x, value.major_axis.y, value.major_axis.z],
                [value.normal.x, value.normal.y, value.normal.z],
                value.minor_axis_ratio,
                value.start_parameter,
                value.end_parameter,
            );
            Some(Entity2DGeometry::Polyline {
                points,
                closed: full || value.is_full(),
            })
        }
        AcadEntity::LwPolyline(value) => Some(Entity2DGeometry::Polyline {
            points: tessellate_bulged_polyline(
                &value
                    .vertices
                    .iter()
                    .map(|vertex| (vertex.location.x, vertex.location.y, vertex.bulge))
                    .collect::<Vec<_>>(),
                value.is_closed,
                value.elevation,
                value.normal,
            ),
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
            points: tessellate_bulged_polyline(
                &value
                    .vertices
                    .iter()
                    .map(|vertex| (vertex.location.x, vertex.location.y, vertex.bulge))
                    .collect::<Vec<_>>(),
                value.is_closed(),
                value.elevation,
                value.normal,
            ),
            closed: value.is_closed(),
        }),
        AcadEntity::Spline(value) => Some(Entity2DGeometry::Polyline {
            points: tessellate_spline(value),
            closed: value.flags.closed,
        }),
        AcadEntity::Text(value) => {
            let axes = ocs_axes([value.normal.x, value.normal.y, value.normal.z])?;
            let parsed = parse_single_line_text(&value.value);
            let fitted = matches!(
                value.horizontal_alignment,
                TextHorizontalAlignment::Aligned | TextHorizontalAlignment::Fit
            );
            let aligned = value
                .alignment_point
                .filter(|point| point.x.is_finite() && point.y.is_finite() && point.z.is_finite());
            let uses_alignment_point = aligned.is_some()
                && (!matches!(value.horizontal_alignment, TextHorizontalAlignment::Left)
                    || !matches!(value.vertical_alignment, TextVerticalAlignment::Baseline));
            let origin = if uses_alignment_point && !fitted {
                aligned.unwrap()
            } else {
                value.insertion_point
            };
            let (rotation, target_width) = if fitted {
                aligned.map_or((value.rotation, None), |end| {
                    let delta = end - value.insertion_point;
                    (delta.y.atan2(delta.x), Some(delta.x.hypot(delta.y)))
                })
            } else {
                (value.rotation, None)
            };
            let origin = text_frame.apply(axes_point(axes, origin));
            Some(Entity2DGeometry::Text {
                origin: point(origin.x, origin.y),
                value: parsed.value,
                height: value.height.abs(),
                height_reference: cad_core::TextHeightReference2D::CapHeight,
                rotation,
                width_factor: positive_or(value.width_factor, style_width(drawing, &value.style)),
                oblique_angle: if value.oblique_angle.is_finite() {
                    value.oblique_angle
                } else {
                    0.0
                },
                horizontal_alignment: if fitted {
                    TextHorizontalAlignment2D::Left
                } else {
                    match value.horizontal_alignment {
                        TextHorizontalAlignment::Center | TextHorizontalAlignment::Middle => {
                            TextHorizontalAlignment2D::Center
                        }
                        TextHorizontalAlignment::Right => TextHorizontalAlignment2D::Right,
                        _ => TextHorizontalAlignment2D::Left,
                    }
                },
                vertical_alignment: if matches!(
                    value.horizontal_alignment,
                    TextHorizontalAlignment::Middle
                ) {
                    TextVerticalAlignment2D::Middle
                } else {
                    match value.vertical_alignment {
                        TextVerticalAlignment::Bottom => TextVerticalAlignment2D::Bottom,
                        TextVerticalAlignment::Middle => TextVerticalAlignment2D::Middle,
                        TextVerticalAlignment::Top => TextVerticalAlignment2D::Top,
                        TextVerticalAlignment::Baseline => TextVerticalAlignment2D::Baseline,
                    }
                },
                target_width,
                uniform_fit: fitted
                    && matches!(value.horizontal_alignment, TextHorizontalAlignment::Aligned),
                wrap_width: None,
                line_spacing: None,
                columns: None,
                background: None,
                mirrored_x: value.generation_flags & 2 != 0,
                mirrored_y: value.generation_flags & 4 != 0,
                font_family: text_font_family(drawing, &value.style),
                shx: text_shx_fonts(drawing, &value.style),
                plane: plane(transformed_axes(axes, text_frame)),
                text_runs: parsed.runs,
                text_warnings: parsed.warnings,
            })
        }
        AcadEntity::MText(value) => {
            let direction = value
                .x_direction
                .unwrap_or_else(|| Vector3::new(value.rotation.cos(), value.rotation.sin(), 0.0));
            let axes = mtext_axes(
                [value.normal.x, value.normal.y, value.normal.z],
                [direction.x, direction.y, direction.z],
            )?;
            let origin = text_frame.apply(value.insertion_point);
            let default_plane = value.normal == Vector3::UNIT_Z && text_frame.is_identity();
            let mut parsed = parse_mtext(&value.value, value.height.abs());
            let column = &value.column_data;
            let columns = if column.column_type != 0
                && value.drawing_direction != acadrust::entities::DrawingDirection::LeftToRight
            {
                parsed
                    .warnings
                    .push("mtext_column_direction_unsupported".to_owned());
                None
            } else {
                mtext_columns(
                    SourceMTextColumns {
                        kind: column.column_type,
                        count: column.column_count,
                        width: column.width,
                        gutter: column.gutter,
                        defined_height: column.defined_height,
                        total_width: column.total_width,
                        heights: &column.heights,
                        flow_reversed: column.flow_reversed,
                        auto_height: column.auto_height,
                    },
                    &parsed.column_breaks,
                    &mut parsed.warnings,
                )
            };
            if column.column_type != 0 && columns.is_none() {
                parsed.warnings.push("mtext_columns_flattened".to_owned());
            }
            let line_spacing = mtext_line_spacing(
                value.line_spacing_factor,
                value.line_spacing_style == acadrust::entities::LineSpacingStyle::Exactly,
                &mut parsed.warnings,
            );
            let mut background = mtext_background(
                value.background_fill_flags,
                value.background_scale,
                match value.background_color {
                    AcadColor::ByLayer => cad_core::MTextBackgroundColor2D::ByLayer,
                    AcadColor::ByBlock => cad_core::MTextBackgroundColor2D::ByBlock,
                    _ => cad_core::MTextBackgroundColor2D::Explicit,
                },
                acad_color(value.background_color, 0xffe5e7eb),
                value.background_transparency as u32,
                &mut parsed.warnings,
            );
            if let Some(background) = &mut background {
                background.layout_supported = column.column_type == 0 || columns.is_some();
            }
            let (horizontal_alignment, vertical_alignment) = match value.attachment_point {
                AttachmentPoint::TopLeft => (
                    TextHorizontalAlignment2D::Left,
                    TextVerticalAlignment2D::Top,
                ),
                AttachmentPoint::TopCenter => (
                    TextHorizontalAlignment2D::Center,
                    TextVerticalAlignment2D::Top,
                ),
                AttachmentPoint::TopRight => (
                    TextHorizontalAlignment2D::Right,
                    TextVerticalAlignment2D::Top,
                ),
                AttachmentPoint::MiddleLeft => (
                    TextHorizontalAlignment2D::Left,
                    TextVerticalAlignment2D::Middle,
                ),
                AttachmentPoint::MiddleCenter => (
                    TextHorizontalAlignment2D::Center,
                    TextVerticalAlignment2D::Middle,
                ),
                AttachmentPoint::MiddleRight => (
                    TextHorizontalAlignment2D::Right,
                    TextVerticalAlignment2D::Middle,
                ),
                AttachmentPoint::BottomLeft => (
                    TextHorizontalAlignment2D::Left,
                    TextVerticalAlignment2D::Bottom,
                ),
                AttachmentPoint::BottomCenter => (
                    TextHorizontalAlignment2D::Center,
                    TextVerticalAlignment2D::Bottom,
                ),
                AttachmentPoint::BottomRight => (
                    TextHorizontalAlignment2D::Right,
                    TextVerticalAlignment2D::Bottom,
                ),
            };
            Some(Entity2DGeometry::Text {
                origin: point(origin.x, origin.y),
                value: parsed.value,
                height: value.height.abs(),
                height_reference: cad_core::TextHeightReference2D::CapHeight,
                rotation: if default_plane {
                    direction.y.atan2(direction.x)
                } else {
                    0.0
                },
                width_factor: style_width(drawing, &value.style),
                oblique_angle: style_oblique(drawing, &value.style),
                horizontal_alignment,
                vertical_alignment,
                target_width: None,
                uniform_fit: false,
                wrap_width: columns.as_ref().map(|column| column.width).or_else(|| {
                    (value.rectangle_width.is_finite() && value.rectangle_width > 0.0)
                        .then_some(value.rectangle_width)
                }),
                line_spacing: Some(line_spacing),
                columns,
                background,
                mirrored_x: style_mirrored_x(drawing, &value.style),
                mirrored_y: style_mirrored_y(drawing, &value.style),
                font_family: text_font_family(drawing, &value.style),
                shx: text_shx_fonts(drawing, &value.style),
                plane: if default_plane {
                    None
                } else {
                    plane(transformed_axes(axes, text_frame))
                },
                text_runs: parsed.runs,
                text_warnings: parsed.warnings,
            })
        }
        _ => None,
    }
}

fn text_style<'a>(
    drawing: &'a CadDocument,
    style_name: &str,
) -> Option<&'a acadrust::tables::TextStyle> {
    drawing
        .text_styles
        .iter()
        .find(|style| style.name.eq_ignore_ascii_case(style_name))
}

fn positive_or(value: f64, fallback: f64) -> f64 {
    if value.is_finite() && value.abs() > 1e-9 {
        value.abs()
    } else if fallback.is_finite() && fallback.abs() > 1e-9 {
        fallback.abs()
    } else {
        1.0
    }
}

fn style_width(drawing: &CadDocument, style_name: &str) -> f64 {
    positive_or(
        text_style(drawing, style_name).map_or(1.0, |style| style.width_factor),
        1.0,
    )
}

fn style_oblique(drawing: &CadDocument, style_name: &str) -> f64 {
    text_style(drawing, style_name).map_or(0.0, |style| {
        if style.oblique_angle.is_finite() {
            style.oblique_angle
        } else {
            0.0
        }
    })
}

fn style_mirrored_x(drawing: &CadDocument, style_name: &str) -> bool {
    text_style(drawing, style_name).is_some_and(|style| style.flags.backward)
}

fn style_mirrored_y(drawing: &CadDocument, style_name: &str) -> bool {
    text_style(drawing, style_name).is_some_and(|style| style.flags.upside_down)
}

fn text_shx_fonts(drawing: &CadDocument, style_name: &str) -> Option<cad_core::ShxFonts2D> {
    let style = text_style(drawing, style_name)?;
    if !style.true_type_font.trim().is_empty() {
        return None;
    }
    cad_core::ShxFonts2D::from_style(&style.font_file, &style.big_font_file)
}

fn text_font_family(drawing: &CadDocument, style_name: &str) -> Option<String> {
    let style = text_style(drawing, style_name)?;
    let preferred = style.true_type_font.trim();
    if !preferred.is_empty() {
        return Some(preferred.split('|').next().unwrap_or(preferred).to_owned());
    }
    let font_file = style.font_file.trim();
    let extension = Path::new(font_file)
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or_default();
    if extension.eq_ignore_ascii_case("ttf") || extension.eq_ignore_ascii_case("otf") {
        return Path::new(font_file)
            .file_stem()
            .and_then(|stem| stem.to_str())
            .map(str::to_owned);
    }
    // Autodesk SHX files are not redistributed. The bundled OFL CJK family is
    // deterministic and covers Chinese/Japanese/Korean plus Latin/Cyrillic.
    Some("CADView Noto CJK".to_owned())
}

fn entity_stroke_width(source: &AcadEntity) -> f64 {
    match source {
        AcadEntity::LwPolyline(value) => {
            value
                .vertices
                .iter()
                .fold(value.constant_width.abs(), |width, vertex| {
                    width
                        .max(vertex.start_width.abs())
                        .max(vertex.end_width.abs())
                })
        }
        AcadEntity::Polyline2D(value) => value.vertices.iter().fold(
            value.start_width.abs().max(value.end_width.abs()),
            |width, vertex| {
                width
                    .max(vertex.start_width.abs())
                    .max(vertex.end_width.abs())
            },
        ),
        _ => 0.0,
    }
}

fn tessellate_bulged_polyline(
    vertices: &[(f64, f64, f64)],
    closed: bool,
    elevation: f64,
    normal: Vector3,
) -> Vec<Point2> {
    let ocs = Matrix3::arbitrary_axis(normal);
    ocs_curves::tessellate_bulged_polyline(vertices, closed, |x, y| {
        let world = ocs * Vector3::new(x, y, elevation);
        point(world.x, world.y)
    })
}

/// A MULTILEADER part drawn with the entity's layer; ByBlock parts follow
/// the MULTILEADER's own color.
fn part_common(base: &EntityCommon, color: AcadColor) -> EntityCommon {
    let mut common = base.clone();
    if color != AcadColor::ByBlock {
        common.color = color;
    }
    common
}

fn cm_color(color: AcadColor) -> mleader::CmColor {
    match color {
        AcadColor::ByLayer => mleader::CmColor::ByLayer,
        AcadColor::ByBlock => mleader::CmColor::ByBlock,
        AcadColor::Index(index) => mleader::CmColor::Aci(index),
        AcadColor::Rgb { r, g, b } => {
            mleader::CmColor::Rgb(((r as u32) << 16) | ((g as u32) << 8) | b as u32)
        }
    }
}

fn mleader_model(leader: &acadrust::entities::MultiLeader) -> mleader::MLeaderModel {
    use acadrust::entities::{MultiLeaderPathType as P, TextAttachmentPointType as T};
    let array = |value: Vector3| [value.x, value.y, value.z];
    let context = &leader.context;
    mleader::MLeaderModel {
        branches: context
            .leader_roots
            .iter()
            .map(|root| mleader::LeaderBranch {
                lines: root
                    .lines
                    .iter()
                    .map(|line| mleader::LeaderLine {
                        points: line.points.iter().copied().map(array).collect(),
                    })
                    .collect(),
                last_point: Some(array(root.connection_point)),
                dogleg: array(root.direction),
                dogleg_length: root.landing_distance,
            })
            .collect(),
        path: match leader.path_type {
            P::Invisible => mleader::LeaderPath::Invisible,
            P::Spline => mleader::LeaderPath::Spline,
            P::StraightLineSegments => mleader::LeaderPath::Straight,
        },
        line_color: cm_color(leader.line_color),
        dogleg_enabled: leader.enable_dogleg,
        arrowhead_size: if context.arrowhead_size > 0.0 {
            context.arrowhead_size
        } else {
            leader.arrowhead_size * leader.scale_factor
        },
        arrowhead_handle: leader.arrowhead_handle.map(u64::from),
        text: (context.has_text_contents && !context.text_string.is_empty()).then(|| {
            mleader::MLeaderText {
                value: context.text_string.clone(),
                location: array(context.text_location),
                direction: array(context.text_direction),
                normal: array(context.text_normal),
                height: context.text_height,
                width: context.text_width,
                line_spacing_factor: context.line_spacing_factor,
                alignment: match context.text_attachment_point {
                    T::Left => 1,
                    T::Center => 2,
                    T::Right => 3,
                },
                style_handle: context.text_style_handle.map(u64::from),
                color: cm_color(context.text_color),
            }
        }),
        block: context
            .block_content_handle
            .filter(|_| context.has_block_contents)
            .map(|handle| mleader::MLeaderBlock {
                block_handle: u64::from(handle),
                location: array(context.block_content_location),
                normal: array(context.block_content_normal),
                scale: array(context.block_content_scale),
                rotation: context.block_rotation,
                color: cm_color(context.block_content_color),
            }),
    }
}

fn has_circular_arcs(entity: &AcadEntity) -> bool {
    match entity {
        AcadEntity::Arc(_) | AcadEntity::Circle(_) => true,
        AcadEntity::LwPolyline(value) => value.vertices.iter().any(|v| v.bulge != 0.0),
        AcadEntity::Polyline2D(value) => value.vertices.iter().any(|v| v.bulge != 0.0),
        _ => false,
    }
}

/// XY part of a block frame (the Z column only matters for tilted planes).
fn affine_from_transform(transform: &Transform) -> Affine2 {
    let origin = transform.apply(Vector3::ZERO);
    let x = transform.apply_rotation(Vector3::new(1.0, 0.0, 0.0));
    let y = transform.apply_rotation(Vector3::new(0.0, 1.0, 0.0));
    Affine2 {
        a: x.x,
        b: x.y,
        c: y.x,
        d: y.y,
        tx: origin.x,
        ty: origin.y,
    }
}

fn tessellate_spline(spline: &acadrust::entities::Spline) -> Vec<Point2> {
    let array = |value: &Vector3| [value.x, value.y, value.z];
    let control_points = spline.control_points.iter().map(array).collect::<Vec<_>>();
    let fit_points = spline.fit_points.iter().map(array).collect::<Vec<_>>();
    curves::tessellate_spline(&curves::SplineSource {
        degree: spline.degree,
        knots: &spline.knots,
        control_points: &control_points,
        weights: &spline.weights,
        fit_points: &fit_points,
        closed: spline.flags.closed,
    })
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
        entities::{DimensionLinear, Insert, LwPolyline, Point as AcadPoint, Solid, Spline, Text},
        tables::BlockRecord,
        CadDocument, DwgWriter, EntityType, Line, Vector2, Vector3,
    };

    #[test]
    fn detects_dwg_magic_without_extension() {
        assert_eq!(DwgAdapter.probe(b"AC1032", None), 100);
    }

    #[test]
    fn nested_mtext_background_inherits_owning_block_not_text_ink() {
        let mut drawing = CadDocument::new();
        let mut block = BlockRecord::new("MASK");
        block.handle = drawing.allocate_handle();
        let owner = block.handle;
        drawing.block_records.add(block).unwrap();
        let mut paragraph = acadrust::entities::MText::with_value("中文 العربية", Vector3::ZERO);
        paragraph.common.owner_handle = owner;
        paragraph.common.color = AcadColor::from_index(1); // red ink
        paragraph.background_color = AcadColor::ByBlock;
        paragraph.background_fill_flags = 17;
        paragraph.background_scale = 2.0;
        drawing.add_entity(AcadEntity::MText(paragraph)).unwrap();
        let mut insert = acadrust::entities::Insert::new("MASK", Vector3::new(100.0, 200.0, 0.0));
        insert.common.color = AcadColor::from_index(5); // blue background
        drawing.add_entity(AcadEntity::Insert(insert)).unwrap();
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("mask.dwg");
        DwgWriter::write_to_file(&path, &drawing).unwrap();
        let opened = DwgAdapter
            .open_path(&path, "mask.dwg", &CancellationToken::default(), None)
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!()
        };
        assert_eq!(scene.entities.len(), 1);
        assert_eq!(scene.entities[0].color_argb, 0xffff0000);
        let Entity2DGeometry::Text {
            background: Some(background),
            origin,
            ..
        } = &scene.entities[0].geometry
        else {
            panic!()
        };
        assert_eq!(*origin, Point2::new(100.0, 200.0));
        assert_eq!(
            background.color_mode,
            cad_core::MTextBackgroundColor2D::Explicit
        );
        assert_eq!(
            (
                background.fill,
                background.frame,
                background.scale,
                background.color_argb
            ),
            (true, true, 2.0, 0xff0000ff)
        );
    }

    #[test]
    fn dwg_text_ocs_and_mtext_wcs_planes_survive_the_binary_reader() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("text-planes.dwg");
        let mut drawing = CadDocument::new();
        let mut text = Text::with_value("中文 العربية", Vector3::new(10.0, 20.0, 30.0));
        text.normal = Vector3::new(0.0, 0.6, 0.8);
        drawing.add_entity(EntityType::Text(text)).unwrap();
        let mut mtext = acadrust::entities::MText::new();
        mtext.value = "日本語 বাংলা".to_owned();
        mtext.insertion_point = Vector3::new(100.0, 200.0, 30.0);
        mtext.normal = Vector3::new(0.0, 1.0, 0.0);
        mtext.x_direction = Some(Vector3::new(0.0, 0.0, 1.0));
        drawing.add_entity(EntityType::MText(mtext)).unwrap();
        DwgWriter::write_to_file(&path, &drawing).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        let opened = DwgAdapter
            .open(
                &bytes,
                "planes.dwg",
                Some(&path),
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!()
        };
        let Entity2DGeometry::Text {
            origin,
            plane: Some(plane),
            ..
        } = &scene.entities[0].geometry
        else {
            panic!("TEXT must retain its projected plane")
        };
        assert!((origin.x + 10.0).abs() < 1e-12);
        assert!((origin.y - 2.0).abs() < 1e-12);
        assert_eq!(plane.xx, -1.0);
        assert!((plane.yy + 0.8).abs() < 1e-12);
        let Entity2DGeometry::Text {
            origin,
            rotation,
            plane: Some(plane),
            ..
        } = &scene.entities[1].geometry
        else {
            panic!("MTEXT must retain even a vertical WCS direction")
        };
        assert_eq!(*origin, Point2::new(100.0, 200.0));
        assert_eq!(*rotation, 0.0);
        assert_eq!(
            (plane.xx, plane.xy, plane.yx, plane.yy),
            (0.0, 1.0, 0.0, 0.0)
        );
    }

    #[test]
    fn mirrored_dwg_arcs_use_their_ocs_in_model_space_and_blocks() {
        // DWG stores ARC centers and angles in the OCS. A (0,0,-1) normal is
        // what CAD mirroring produces: OCS X is world -X.
        fn arc(normal_z: f64, owner: Option<Handle>) -> AcadEntity {
            let mut arc = acadrust::entities::Arc::new();
            arc.center = Vector3::new(3.0, 4.0, 0.0);
            arc.radius = 2.0;
            arc.start_angle = 0.0;
            arc.end_angle = std::f64::consts::FRAC_PI_2;
            arc.normal = Vector3::new(0.0, 0.0, normal_z);
            if let Some(owner) = owner {
                arc.common.owner_handle = owner;
            }
            AcadEntity::Arc(arc)
        }
        let mut drawing = CadDocument::new();
        drawing.add_entity(arc(-1.0, None)).unwrap();
        let mut mirrored = BlockRecord::new("MIRRORED");
        mirrored.handle = drawing.allocate_handle();
        let mirrored_handle = mirrored.handle;
        drawing.block_records.add(mirrored).unwrap();
        drawing
            .add_entity(arc(-1.0, Some(mirrored_handle)))
            .unwrap();
        let mut plain = BlockRecord::new("PLAIN");
        plain.handle = drawing.allocate_handle();
        let plain_handle = plain.handle;
        drawing.block_records.add(plain).unwrap();
        drawing.add_entity(arc(1.0, Some(plain_handle))).unwrap();
        let mut based = BlockRecord::new("BASED");
        based.handle = drawing.allocate_handle();
        based.base_point = Vector3::new(1.0, 1.0, 0.0);
        let based_handle = based.handle;
        drawing.block_records.add(based).unwrap();
        drawing.add_entity(arc(-1.0, Some(based_handle))).unwrap();
        drawing
            .add_entity(AcadEntity::Insert(Insert::new(
                "BASED",
                Vector3::new(0.0, -100.0, 0.0),
            )))
            .unwrap();
        drawing
            .add_entity(AcadEntity::Insert(Insert::new(
                "MIRRORED",
                Vector3::new(100.0, 200.0, 0.0),
            )))
            .unwrap();
        drawing
            .add_entity(AcadEntity::Insert(
                Insert::new("PLAIN", Vector3::new(100.0, 0.0, 0.0)).with_scale(-1.0, 1.0, 1.0),
            ))
            .unwrap();
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("mirrored-arcs.dwg");
        DwgWriter::write_to_file(&path, &drawing).unwrap();
        let opened = DwgAdapter
            .open_path(
                &path,
                "mirrored-arcs.dwg",
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!()
        };
        let arcs = scene
            .entities
            .iter()
            .filter_map(|entity| match entity.geometry {
                Entity2DGeometry::Arc {
                    center,
                    radius,
                    start_angle,
                    end_angle,
                } => Some((center, radius, start_angle, end_angle)),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(arcs.len(), 4, "{:?}", scene.entities);
        // Every case is the world arc running counter-clockwise from 90 to
        // 180 degrees: model space at (-3, 4), the -Z block arc translated by
        // (100, 200), the +Z block arc reflected by an X scale of -1, and the
        // -Z arc whose block base point (1, 1) is subtracted in world space.
        for expected in [(-3.0, 4.0), (97.0, 204.0), (97.0, 4.0), (-4.0, -97.0)] {
            let (center, radius, start, end) = arcs
                .iter()
                .find(|arc| {
                    (arc.0.x - expected.0).abs() < 1e-9 && (arc.0.y - expected.1).abs() < 1e-9
                })
                .unwrap_or_else(|| panic!("no arc centered at {expected:?}: {arcs:?}"));
            assert!((radius - 2.0).abs() < 1e-12);
            let start = start.rem_euclid(std::f64::consts::TAU);
            let end = end.rem_euclid(std::f64::consts::TAU);
            assert!(
                (start - std::f64::consts::FRAC_PI_2).abs() < 1e-9,
                "{center:?} {start}"
            );
            assert!(
                (end - std::f64::consts::PI).abs() < 1e-9,
                "{center:?} {end}"
            );
        }
    }

    #[test]
    fn nested_dwg_block_text_retains_the_complete_affine_basis() {
        let mut drawing = CadDocument::new();
        let mut child = BlockRecord::new("GLYPHS");
        child.handle = drawing.allocate_handle();
        child.base_point = Vector3::new(5.0, 7.0, 0.0);
        let child_handle = child.handle;
        drawing.block_records.add(child).unwrap();
        let mut text = Text::with_value("中文 العربية বাংলা", Vector3::new(10.0, 20.0, 0.0));
        text.common.owner_handle = child_handle;
        text.height = 12.0;
        text.rotation = 0.3;
        drawing.add_entity(EntityType::Text(text)).unwrap();
        let mut paragraph = acadrust::entities::MText::new();
        paragraph.common.owner_handle = child_handle;
        paragraph.value = "日本語\\Pالعربية বাংলা".to_owned();
        paragraph.insertion_point = Vector3::new(10.0, 20.0, 0.0);
        paragraph.height = 12.0;
        paragraph.rectangle_width = 120.0;
        paragraph.rotation = 0.3;
        drawing.add_entity(EntityType::MText(paragraph)).unwrap();
        let mut parent = BlockRecord::new("ASSEMBLY");
        parent.handle = drawing.allocate_handle();
        parent.base_point = Vector3::new(-4.0, 3.0, 0.0);
        let parent_handle = parent.handle;
        drawing.block_records.add(parent).unwrap();
        let mut inner = Insert::new("GLYPHS", Vector3::new(20.0, 30.0, 0.0))
            .with_scale(2.0, 3.0, 1.0)
            .with_rotation(0.6);
        inner.common.owner_handle = parent_handle;
        drawing.add_entity(EntityType::Insert(inner)).unwrap();
        drawing
            .add_entity(EntityType::Insert(
                Insert::new("ASSEMBLY", Vector3::new(100.0, 200.0, 0.0))
                    .with_scale(-1.0, 2.0, 1.0)
                    .with_rotation(-0.2),
            ))
            .unwrap();
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("affine.dwg");
        DwgWriter::write_to_file(&path, &drawing).unwrap();
        let opened = DwgAdapter
            .open_path(&path, "affine.dwg", &CancellationToken::default(), None)
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!()
        };
        let Entity2DGeometry::Text {
            origin,
            height,
            rotation,
            plane: Some(plane),
            ..
        } = &scene.entities[0].geometry
        else {
            panic!("nested text must preserve its full basis")
        };
        assert_eq!(*height, 12.0);
        assert_eq!(*rotation, 0.3);
        // Independent scale/rotate/translate arithmetic, not the parser's
        // matrix constructor or its own writer's round-trip expectations.
        let rotate = |x: f64, y: f64, angle: f64| {
            (
                x * angle.cos() - y * angle.sin(),
                x * angle.sin() + y * angle.cos(),
            )
        };
        let inner = |x, y| rotate(2.0 * x, 3.0 * y, 0.6);
        let outer = |x: f64, y: f64| rotate(-x, 2.0 * y, -0.2);
        let (x, y) = inner(10.0 - 5.0, 20.0 - 7.0);
        let (x, y) = outer(x + 20.0 + 4.0, y + 30.0 - 3.0);
        assert!((origin.x - (x + 100.0)).abs() < 1e-10);
        assert!((origin.y - (y + 200.0)).abs() < 1e-10);
        for (u, v) in [(1.0, 0.0), (0.0, 1.0), (3.0, -2.0)] {
            let (x, y) = inner(u, v);
            let (x, y) = outer(x, y);
            assert!((plane.xx * u + plane.xy * v - x).abs() < 1e-10);
            assert!((plane.yx * u + plane.yy * v - y).abs() < 1e-10);
        }
        let Entity2DGeometry::Text {
            origin: m_origin,
            height: m_height,
            rotation: m_rotation,
            plane: Some(m_plane),
            wrap_width,
            ..
        } = &scene.entities[1].geometry
        else {
            panic!("MTEXT must preserve its full instance basis")
        };
        assert_eq!(*m_origin, *origin);
        assert_eq!(*m_height, 12.0);
        assert_eq!(*wrap_width, Some(120.0));
        assert_eq!(*m_rotation, 0.0);
        for (u, v) in [(1.0, 0.0), (0.0, 1.0), (3.0, -2.0)] {
            let (x, y) = rotate(u, v, 0.3);
            let (x, y) = inner(x, y);
            let (x, y) = outer(x, y);
            assert!((m_plane.xx * u + m_plane.xy * v - x).abs() < 1e-10);
            assert!((m_plane.yx * u + m_plane.yy * v - y).abs() < 1e-10);
        }
    }

    #[test]
    fn rotated_minsert_places_glyphs_and_geometry_on_the_same_unscaled_grid() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("grid.dwg");
        let mut drawing = CadDocument::new();
        let mut block = BlockRecord::new("GRID");
        block.handle = drawing.allocate_handle();
        let handle = block.handle;
        drawing.block_records.add(block).unwrap();
        let mut text = Text::with_value("中文 日本語 العربية", Vector3::new(4.0, 5.0, 0.0));
        text.common.owner_handle = handle;
        drawing.add_entity(EntityType::Text(text)).unwrap();
        let mut line = Line::from_coords(4.0, 5.0, 0.0, 5.0, 5.0, 0.0);
        line.common.owner_handle = handle;
        drawing.add_entity(EntityType::Line(line)).unwrap();
        let mut insert = Insert::new("GRID", Vector3::new(10.0, 20.0, 0.0))
            .with_scale(2.0, 3.0, 1.0)
            .with_rotation(std::f64::consts::FRAC_PI_2);
        insert.row_count = 2;
        insert.column_count = 2;
        insert.row_spacing = 200.0;
        insert.column_spacing = 100.0;
        drawing.add_entity(EntityType::Insert(insert)).unwrap();
        DwgWriter::write_to_file(&path, &drawing).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        let opened = DwgAdapter
            .open(
                &bytes,
                "grid.dwg",
                Some(&path),
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!()
        };
        assert_eq!(scene.entities.len(), 8);
        for (cell, pair) in scene.entities.chunks(2).enumerate() {
            let expected = Point2::new(
                -5.0 - (cell / 2) as f64 * 200.0,
                28.0 + (cell % 2) as f64 * 100.0,
            );
            let Entity2DGeometry::Text { origin, .. } = pair[0].geometry else {
                panic!()
            };
            let Entity2DGeometry::Line { start, end } = pair[1].geometry else {
                panic!()
            };
            for point in [origin, start] {
                assert!(
                    (point.x - expected.x).abs() < 1e-10,
                    "cell {cell}: {point:?}, expected {expected:?}"
                );
                assert!(
                    (point.y - expected.y).abs() < 1e-10,
                    "cell {cell}: {point:?}, expected {expected:?}"
                );
            }
            assert!((end.x - expected.x).abs() < 1e-10);
            assert!((end.y - expected.y - 2.0).abs() < 1e-10);
        }
    }

    #[test]
    fn binary_minsert_attributes_keep_alignment_flags_and_all_cells() {
        use acadrust::entities::attribute_definition::{HorizontalAlignment, VerticalAlignment};
        use acadrust::entities::AttributeEntity;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("attributes.dwg");
        let mut drawing = CadDocument::new();
        let mut block = BlockRecord::new("ATTR_GRID");
        block.handle = drawing.allocate_handle();
        let handle = block.handle;
        drawing.block_records.add(block).unwrap();
        let mut line = Line::from_coords(0.0, 0.0, 0.0, 1.0, 0.0, 0.0);
        line.common.owner_handle = handle;
        drawing.add_entity(EntityType::Line(line)).unwrap();
        let mut insert = Insert::new("ATTR_GRID", Vector3::new(10.0, 20.0, 0.0))
            .with_array(2, 2, 100.0, 200.0)
            .with_scale(2.0, 3.0, 1.0)
            .with_rotation(std::f64::consts::FRAC_PI_2);
        insert.common.layer = "Labels".to_owned();
        insert.common.color = AcadColor::from_index(5);
        let mut layer = acadrust::tables::Layer::new("Labels");
        layer.handle = drawing.allocate_handle();
        drawing.layers.add(layer).unwrap();
        let mut centered = AttributeEntity::simple("CENTER", "中文 العربية");
        centered.set_position(Vector3::new(0.0, 0.0, 0.0));
        centered.alignment_point = Vector3::new(30.0, 40.0, 0.0);
        centered.horizontal_alignment = HorizontalAlignment::Center;
        centered.vertical_alignment = VerticalAlignment::Top;
        centered.height = 12.0;
        centered.width_factor = 1.3;
        centered.oblique_angle = 0.25;
        centered.text_generation_flags = 2;
        centered.common.color = AcadColor::ByBlock;
        insert.attributes.push(centered);
        let mut fitted = AttributeEntity::simple("FIT", "日本語 বাংলা");
        fitted.set_position(Vector3::new(4.0, 5.0, 0.0));
        fitted.alignment_point = Vector3::new(34.0, 45.0, 0.0);
        fitted.horizontal_alignment = HorizontalAlignment::Fit;
        fitted.height = 12.0;
        fitted.text_generation_flags = 4;
        insert.attributes.push(fitted.clone());
        fitted.value = "ไทย aligned".to_owned();
        fitted.tag = "ALIGNED".to_owned();
        fitted.horizontal_alignment = HorizontalAlignment::Aligned;
        insert.attributes.push(fitted);
        let mut middle = AttributeEntity::simple("MIDDLE", "Middle עברית");
        middle.alignment_point = Vector3::new(-10.0, 30.0, 0.0);
        middle.horizontal_alignment = HorizontalAlignment::Middle;
        middle.height = 12.0;
        middle.common.color = AcadColor::ByBlock;
        insert.attributes.push(middle);
        let mut hidden = AttributeEntity::simple("HIDDEN", "不可见 invisible");
        hidden.flags.invisible = true;
        insert.attributes.push(hidden);
        let mut hidden = AttributeEntity::simple("COMMON_HIDDEN", "共同不可见");
        hidden.common.invisible = true;
        insert.attributes.push(hidden);
        drawing.add_entity(EntityType::Insert(insert)).unwrap();
        DwgWriter::write_to_file(&path, &drawing).unwrap();
        let opened = DwgAdapter
            .open_path(&path, "attributes.dwg", &CancellationToken::default(), None)
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!()
        };
        assert_eq!(
            scene.entities.len(),
            20,
            "4 lines and 16 visible attribute instances"
        );
        let labels = scene
            .layers
            .iter()
            .find(|layer| layer.name == "Labels")
            .unwrap()
            .id;
        for (value, start, horizontal, vertical, target, uniform, mirror_x, mirror_y) in [
            (
                "中文 العربية",
                Point2::new(30.0, 40.0),
                TextHorizontalAlignment2D::Center,
                TextVerticalAlignment2D::Top,
                None,
                false,
                true,
                false,
            ),
            (
                "日本語 বাংলা",
                Point2::new(4.0, 5.0),
                TextHorizontalAlignment2D::Left,
                TextVerticalAlignment2D::Baseline,
                Some(50.0),
                false,
                false,
                true,
            ),
            (
                "ไทย aligned",
                Point2::new(4.0, 5.0),
                TextHorizontalAlignment2D::Left,
                TextVerticalAlignment2D::Baseline,
                Some(50.0),
                true,
                false,
                true,
            ),
            (
                "Middle עברית",
                Point2::new(-10.0, 30.0),
                TextHorizontalAlignment2D::Center,
                TextVerticalAlignment2D::Middle,
                None,
                false,
                false,
                false,
            ),
        ] {
            let matches = scene.entities.iter().filter(|entity| matches!(&entity.geometry, Entity2DGeometry::Text { value: text, .. } if text == value)).collect::<Vec<_>>();
            assert_eq!(matches.len(), 4);
            for (cell, entity) in matches.iter().enumerate() {
                let Entity2DGeometry::Text {
                    origin,
                    height,
                    rotation,
                    horizontal_alignment,
                    vertical_alignment,
                    target_width,
                    uniform_fit,
                    mirrored_x,
                    mirrored_y,
                    ..
                } = &entity.geometry
                else {
                    panic!()
                };
                assert!((origin.x - (start.x - (cell / 2) as f64 * 200.0)).abs() < 1e-10);
                assert!((origin.y - (start.y + (cell % 2) as f64 * 100.0)).abs() < 1e-10);
                assert_eq!(*height, 12.0);
                assert_eq!(
                    std::mem::discriminant(horizontal_alignment),
                    std::mem::discriminant(&horizontal)
                );
                assert_eq!(
                    std::mem::discriminant(vertical_alignment),
                    std::mem::discriminant(&vertical)
                );
                assert_eq!(*target_width, target);
                assert_eq!(*uniform_fit, uniform);
                assert_eq!(*mirrored_x, mirror_x);
                assert_eq!(*mirrored_y, mirror_y);
                assert_eq!(entity.layer_id, labels);
                if target.is_some() {
                    assert!((*rotation - 40.0_f64.atan2(30.0)).abs() < 1e-12);
                } else {
                    assert_eq!(entity.color_argb, 0xff0000ff);
                }
            }
        }
    }

    #[test]
    fn tilted_attribute_uses_the_alignment_point_and_enclosing_frame_once() {
        use acadrust::entities::attribute_definition::{HorizontalAlignment, VerticalAlignment};
        let mut attribute = acadrust::entities::AttributeEntity::simple("T", r"{中文} \Pالعربية");
        attribute.normal = Vector3::new(0.0, 0.6, 0.8);
        attribute.insertion_point = Vector3::new(1.0, 2.0, 3.0);
        attribute.alignment_point = Vector3::new(30.0, 40.0, 50.0);
        attribute.height = 12.0;
        attribute.horizontal_alignment = HorizontalAlignment::Center;
        attribute.vertical_alignment = VerticalAlignment::Top;
        let frame = Transform::from_matrix(
            Matrix4::translation(100.0, 200.0, 300.0)
                * Matrix4::rotation_z(-0.2)
                * Matrix4::scaling(-1.0, 2.0, 3.0),
        );
        let geometry = normalize_attribute(&attribute, &CadDocument::new(), &frame).unwrap();
        let Entity2DGeometry::Text {
            origin,
            height,
            plane: Some(plane),
            value,
            ..
        } = geometry
        else {
            panic!()
        };
        // OCS (30,40,50) maps to WCS (-30,-2,64), then S/R/T.
        let c = (-0.2_f64).cos();
        let s = (-0.2_f64).sin();
        assert!((origin.x - (100.0 + 30.0 * c + 4.0 * s)).abs() < 1e-10);
        assert!((origin.y - (200.0 + 30.0 * s - 4.0 * c)).abs() < 1e-10);
        assert!((plane.xx - c).abs() < 1e-12);
        assert!((plane.yx - s).abs() < 1e-12);
        assert!((plane.xy - 1.6 * s).abs() < 1e-12);
        assert!((plane.yy + 1.6 * c).abs() < 1e-12);
        assert_eq!(height, 12.0);
        assert_eq!(value, r"{中文} \Pالعربية");
    }

    #[test]
    fn embedded_attribute_uses_authoritative_paragraph_and_enclosing_frame_once() {
        use acadrust::entities::{AttributeEntity, LineSpacingStyle, MText};
        let drawing = CadDocument::new();
        let mut attribute = AttributeEntity::simple("T", "LEGACY DO NOT DISPLAY");
        attribute.insertion_point = Vector3::new(-1000.0, -2000.0, 0.0);
        attribute.height = 2.0;
        attribute.is_multiline = true;
        let mut paragraph =
            MText::with_value(r"中文\Pالعربية\P日本語", Vector3::new(25.0, 40.0, 10.0));
        paragraph.height = 8.0;
        paragraph.rectangle_width = 120.0;
        paragraph.normal = Vector3::new(0.0, 0.6, 0.8);
        paragraph.x_direction = Some(Vector3::UNIT_X);
        paragraph.attachment_point = AttachmentPoint::BottomRight;
        paragraph.line_spacing_factor = 1.4;
        paragraph.line_spacing_style = LineSpacingStyle::Exactly;
        attribute.embedded_mtext = Some(paragraph);
        let frame = Transform::from_matrix(
            Matrix4::translation(100.0, 200.0, 0.0) * Matrix4::scaling(2.0, 3.0, 1.0),
        );
        let geometry = normalize_attribute(&attribute, &drawing, &frame).unwrap();
        let Entity2DGeometry::Text {
            origin,
            value,
            height,
            wrap_width,
            line_spacing,
            plane,
            horizontal_alignment,
            vertical_alignment,
            text_warnings,
            ..
        } = geometry
        else {
            panic!("expected multiline attribute text");
        };
        assert_eq!(origin, point(150.0, 320.0));
        assert_eq!(value, "中文\nالعربية\n日本語");
        assert_eq!(height, 8.0); // local height, scale is carried by the basis
        assert_eq!(wrap_width, Some(120.0));
        assert!(matches!(
            horizontal_alignment,
            TextHorizontalAlignment2D::Right
        ));
        assert!(matches!(
            vertical_alignment,
            TextVerticalAlignment2D::Bottom
        ));
        let basis = plane.unwrap();
        assert!((basis.xx - 2.0).abs() < 1e-12);
        assert!(basis.xy.abs() < 1e-12 && basis.yx.abs() < 1e-12);
        assert!((basis.yy - 2.4).abs() < 1e-12);
        let spacing = line_spacing.unwrap();
        assert_eq!(spacing.factor, 1.4);
        assert!(matches!(
            spacing.style,
            cad_core::MTextLineSpacingStyle2D::Exact
        ));
        assert!(!text_warnings
            .iter()
            .any(|warning| warning.contains("layout is unavailable")));
    }

    #[test]
    fn constant_definitions_survive_binary_read_and_render_each_block_cell() {
        use acadrust::entities::{
            attribute_definition::{HorizontalAlignment, VerticalAlignment},
            AttributeDefinition, Insert,
        };
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("constant-definitions.dwg");
        let mut drawing = CadDocument::new();
        let mut block = BlockRecord::new("CONSTANTS");
        block.handle = drawing.allocate_handle();
        block.base_point = Vector3::new(5.0, 7.0, 0.0);
        let owner = block.handle;
        drawing.block_records.add(block).unwrap();
        let mut style = acadrust::tables::TextStyle::new("Arabic");
        style.handle = drawing.allocate_handle();
        style.font_file = "NotoSansArabic-Regular.ttf".to_owned();
        drawing.text_styles.add(style).unwrap();
        let mut definition = AttributeDefinition::new(
            "FIXED".to_owned(),
            "Never display prompt".to_owned(),
            "中文 العربية".to_owned(),
        );
        definition.common.owner_handle = owner;
        definition.common.color = AcadColor::ByBlock;
        definition.flags.constant = true;
        definition.insertion_point = Vector3::new(-999.0, -999.0, 0.0);
        definition.alignment_point = Vector3::new(10.0, 20.0, 0.0);
        definition.horizontal_alignment = HorizontalAlignment::Center;
        definition.vertical_alignment = VerticalAlignment::Top;
        definition.height = 8.0;
        definition.width_factor = 1.25;
        definition.oblique_angle = 0.2;
        definition.text_generation_flags = 2;
        definition.text_style = "Arabic".to_owned();
        definition.field_length = 7;
        definition.lock_position = true;
        drawing
            .add_entity(AcadEntity::AttributeDefinition(definition.clone()))
            .unwrap();
        for (tag, invisible, common_hidden, constant) in [
            ("HIDDEN", true, false, true),
            ("COMMON_HIDDEN", false, true, true),
            ("VARIABLE", false, false, false),
        ] {
            let mut excluded = definition.clone();
            excluded.common.handle = Handle::NULL;
            excluded.tag = tag.to_owned();
            excluded.default_value = tag.to_owned();
            excluded.flags.invisible = invisible;
            excluded.common.invisible = common_hidden;
            excluded.flags.constant = constant;
            drawing
                .add_entity(AcadEntity::AttributeDefinition(excluded))
                .unwrap();
        }
        let mut layer = acadrust::tables::Layer::new("Labels");
        layer.handle = drawing.allocate_handle();
        drawing.layers.add(layer).unwrap();
        let mut insert = Insert::new("CONSTANTS", Vector3::new(100.0, 200.0, 0.0))
            .with_scale(2.0, 3.0, 1.0)
            .with_rotation(std::f64::consts::FRAC_PI_2)
            .with_array(2, 2, 100.0, 200.0);
        insert.common.layer = "Labels".to_owned();
        insert.common.color = AcadColor::from_index(5);
        drawing.add_entity(AcadEntity::Insert(insert)).unwrap();
        DwgWriter::write_to_file(&path, &drawing).unwrap();
        let mut reader =
            DwgReader::from_file_with_options(&path, DwgReadOptions::default()).unwrap();
        let decoded = reader.read().unwrap();
        let read_definition = decoded
            .entities()
            .find_map(|entity| match entity {
                AcadEntity::AttributeDefinition(value) if value.tag == "FIXED" => Some(value),
                _ => None,
            })
            .unwrap();
        assert_eq!(read_definition.text_style, "Arabic");
        assert_eq!(
            read_definition.alignment_point,
            Vector3::new(10.0, 20.0, 0.0)
        );
        assert_eq!(read_definition.text_generation_flags, 2);
        assert_eq!(read_definition.field_length, 7);
        assert!(read_definition.lock_position && read_definition.flags.constant);
        let opened = DwgAdapter
            .open_path(&path, "constants.dwg", &CancellationToken::default(), None)
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!()
        };
        assert_eq!(
            scene.entities.len(),
            4,
            "Only the fixed visible value, once per cell"
        );
        let labels = scene
            .layers
            .iter()
            .find(|layer| layer.name == "Labels")
            .unwrap()
            .id;
        for (cell, entity) in scene.entities.iter().enumerate() {
            assert_eq!(entity.layer_id, labels);
            assert_eq!(entity.color_argb, acad_color(AcadColor::from_index(5), 0));
            let Entity2DGeometry::Text {
                origin,
                value,
                height,
                width_factor,
                oblique_angle,
                horizontal_alignment,
                vertical_alignment,
                mirrored_x,
                font_family,
                plane,
                ..
            } = &entity.geometry
            else {
                panic!()
            };
            assert_eq!(value, "中文 العربية");
            assert!((origin.x - (61.0 - (cell / 2) as f64 * 200.0)).abs() < 1e-10);
            assert!((origin.y - (210.0 + (cell % 2) as f64 * 100.0)).abs() < 1e-10);
            assert_eq!((*height, *width_factor, *oblique_angle), (8.0, 1.25, 0.2));
            assert!(matches!(
                horizontal_alignment,
                TextHorizontalAlignment2D::Center
            ));
            assert!(matches!(vertical_alignment, TextVerticalAlignment2D::Top));
            assert!(*mirrored_x);
            assert_eq!(font_family.as_deref(), Some("NotoSansArabic-Regular"));
            let basis = plane.unwrap();
            assert!(basis.xx.abs() < 1e-10 && basis.yy.abs() < 1e-10);
            assert!((basis.xy + 3.0).abs() < 1e-10 && (basis.yx - 2.0).abs() < 1e-10);
        }
    }

    #[test]
    fn constant_only_block_array_is_bounded_before_expansion() {
        let mut drawing = CadDocument::new();
        let mut block = BlockRecord::new("CONSTANTS");
        block.handle = drawing.allocate_handle();
        let owner = block.handle;
        drawing.block_records.add(block).unwrap();
        let mut definition = acadrust::entities::AttributeDefinition::new(
            "T".to_owned(),
            String::new(),
            "中文".to_owned(),
        );
        definition.common.owner_handle = owner;
        definition.flags.constant = true;
        drawing
            .add_entity(AcadEntity::AttributeDefinition(definition))
            .unwrap();
        drawing
            .add_entity(AcadEntity::Insert(
                acadrust::entities::Insert::new("CONSTANTS", Vector3::ZERO)
                    .with_array(32767, 32767, 1.0, 1.0),
            ))
            .unwrap();
        let result = build_document(
            drawing,
            None,
            "limit.dwg",
            "test".to_owned(),
            0,
            &CancellationToken::default(),
            None,
        );
        assert!(matches!(result, Err(CadError::ResourceLimit(_))));
    }

    #[test]
    fn invisible_definition_only_array_does_not_visit_empty_cells() {
        let mut drawing = CadDocument::new();
        let mut block = BlockRecord::new("HIDDEN");
        block.handle = drawing.allocate_handle();
        let owner = block.handle;
        drawing.block_records.add(block).unwrap();
        let mut definition = acadrust::entities::AttributeDefinition::new(
            "T".to_owned(),
            String::new(),
            "Invisible".to_owned(),
        );
        definition.common.owner_handle = owner;
        definition.flags.constant = true;
        definition.flags.invisible = true;
        drawing
            .add_entity(AcadEntity::AttributeDefinition(definition))
            .unwrap();
        drawing
            .add_entity(AcadEntity::Insert(
                acadrust::entities::Insert::new("HIDDEN", Vector3::ZERO)
                    .with_array(32767, 32767, 1.0, 1.0),
            ))
            .unwrap();
        // This array has no displayable geometry. It must not loop over a
        // billion empty cells or manufacture an invisible label. The adapter
        // returns the structured no-displayable-geometry error diagnostic.
        let result = build_document(
            drawing,
            None,
            "hidden.dwg",
            "test".to_owned(),
            0,
            &CancellationToken::default(),
            None,
        );
        let opened = result.unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!()
        };
        assert!(scene.entities.is_empty());
        assert!(opened.diagnostics.iter().any(|diagnostic| {
            diagnostic.code == "dwg.no_displayable_geometry"
                && matches!(diagnostic.severity, DiagnosticSeverity::Error)
        }));
    }

    #[test]
    fn nested_constant_paragraph_keeps_original_geometry_and_full_frame() {
        use acadrust::entities::{AttributeDefinition, Insert, MText};
        let mut drawing = CadDocument::new();
        let mut child = BlockRecord::new("PARAGRAPH");
        child.handle = drawing.allocate_handle();
        child.base_point = Vector3::new(5.0, 7.0, 0.0);
        let child_handle = child.handle;
        drawing.block_records.add(child).unwrap();
        let mut definition =
            AttributeDefinition::new("FIXED".to_owned(), "PROMPT".to_owned(), "LEGACY".to_owned());
        definition.common.owner_handle = child_handle;
        definition.flags.constant = true;
        definition.is_multiline = true;
        definition.insertion_point = Vector3::new(-999.0, -999.0, 0.0);
        let mut paragraph =
            MText::with_value(r"中文\Pالعربية\P日本語", Vector3::new(25.0, 40.0, 10.0));
        paragraph.height = 8.0;
        paragraph.rectangle_width = 120.0;
        paragraph.normal = Vector3::new(0.0, 0.6, 0.8);
        paragraph.x_direction = Some(Vector3::UNIT_X);
        definition.embedded_mtext = Some(paragraph);
        drawing
            .add_entity(AcadEntity::AttributeDefinition(definition))
            .unwrap();
        let mut parent = BlockRecord::new("PARENT");
        parent.handle = drawing.allocate_handle();
        let parent_handle = parent.handle;
        drawing.block_records.add(parent).unwrap();
        let mut inner =
            Insert::new("PARAGRAPH", Vector3::new(10.0, 20.0, 0.0)).with_scale(-1.0, 2.0, 1.0);
        inner.common.owner_handle = parent_handle;
        drawing.add_entity(AcadEntity::Insert(inner)).unwrap();
        drawing
            .add_entity(AcadEntity::Insert(
                Insert::new("PARENT", Vector3::new(100.0, 200.0, 0.0)).with_scale(2.0, 3.0, 1.0),
            ))
            .unwrap();
        let opened = build_document(
            drawing,
            None,
            "constant-paragraph.dwg",
            "test".to_owned(),
            0,
            &CancellationToken::default(),
            None,
        )
        .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!()
        };
        assert_eq!(scene.entities.len(), 1);
        let Entity2DGeometry::Text {
            origin,
            value,
            height,
            wrap_width,
            plane,
            ..
        } = &scene.entities[0].geometry
        else {
            panic!()
        };
        assert_eq!(*origin, Point2::new(80.0, 458.0));
        assert_eq!(value, "中文\nالعربية\n日本語");
        assert_eq!(*height, 8.0);
        assert_eq!(*wrap_width, Some(120.0));
        let basis = plane.unwrap();
        assert_eq!(basis.xx, -2.0);
        assert!(basis.xy.abs() < 1e-12 && basis.yx.abs() < 1e-12);
        assert!((basis.yy - 4.8).abs() < 1e-12);
    }

    #[test]
    fn attribute_array_limit_is_checked_before_allocating_empty_block_cells() {
        let mut drawing = CadDocument::new();
        let mut block = BlockRecord::new("EMPTY");
        block.handle = drawing.allocate_handle();
        drawing.block_records.add(block).unwrap();
        let mut insert = Insert::new("EMPTY", Vector3::ZERO).with_array(32767, 32767, 1.0, 1.0);
        insert
            .attributes
            .push(acadrust::entities::AttributeEntity::simple("T", "中文"));
        drawing.add_entity(EntityType::Insert(insert)).unwrap();
        let result = build_document(
            drawing,
            None,
            "limit.dwg",
            "test".to_owned(),
            0,
            &CancellationToken::default(),
            None,
        );
        assert!(matches!(result, Err(CadError::ResourceLimit(_))));
    }

    #[test]
    fn opens_generated_dwg_geometry_end_to_end() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("line.dwg");
        let mut source = CadDocument::new();
        source.header.insertion_units = 4;
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
        assert_eq!(opened.metadata.units.as_deref(), Some("mm"));

        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected a 2D scene");
        };
        assert!(scene
            .entities
            .iter()
            .any(|entity| matches!(entity.geometry, Entity2DGeometry::Line { .. })));
    }

    #[test]
    fn dwg_preserves_mtext_line_spacing_end_to_end() {
        use acadrust::entities::{LineSpacingStyle, MText};
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("spacing.dwg");
        let mut source = CadDocument::new();
        for factor in [0.25, 0.6, 1.0, 4.0] {
            for (style, exact) in [
                (LineSpacingStyle::AtLeast, false),
                (LineSpacingStyle::Exactly, true),
            ] {
                let mut text = MText::new();
                text.value = format!("{factor}:{exact} 中文\\P日本語");
                text.height = 10.0;
                text.line_spacing_factor = factor;
                text.line_spacing_style = style;
                source.add_entity(EntityType::MText(text)).unwrap();
            }
        }
        DwgWriter::write_to_file(&path, &source).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        let opened = DwgAdapter
            .open(
                &bytes,
                "spacing.dwg",
                Some(&path),
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
            assert!((spacing.factor - factor.parse::<f64>().unwrap()).abs() < 1e-12);
            assert_eq!(
                spacing.style == cad_core::MTextLineSpacingStyle2D::Exact,
                exact == "true"
            );
            assert!(text_warnings.is_empty());
            assert!(value.contains("中文\n日本語"));
        }
    }

    #[test]
    fn r2018_dwg_columns_preserve_embedded_envelope_and_manual_breaks() {
        use acadrust::entities::{MText, MTextColumnData};
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("columns.dwg");
        let mut source = CadDocument::new();
        for (kind, count, auto, heights) in [
            (1, 3, false, vec![]),
            (2, 0, true, vec![]),
            (2, 3, false, vec![160.0, 140.0, 0.0]),
        ] {
            let mut text = MText::with_value(
                r"{\H2;日本語😀}\Nالعربية\Nবাংলা",
                Vector3::new(100.0, 200.0, 0.0),
            );
            text.height = 2.5;
            text.rectangle_width = 62.5; // deliberately stale, not column width
            text.rectangle_height = Some(99.0); // embedded column height wins
            text.is_annotative = false;
            text.column_data = MTextColumnData {
                column_type: kind,
                column_count: count,
                auto_height: auto,
                flow_reversed: true,
                width: 50.0,
                gutter: 12.5,
                heights,
                defined_height: 150.0,
                total_width: 175.0,
                total_height: 160.0,
            };
            source.add_entity(EntityType::MText(text)).unwrap();
        }
        DwgWriter::write_to_file(&path, &source).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        let opened = DwgAdapter
            .open(
                &bytes,
                "columns.dwg",
                Some(&path),
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!()
        };
        assert_eq!(scene.entities.len(), 3);
        for (index, entity) in scene.entities.iter().enumerate() {
            let Entity2DGeometry::Text {
                columns: Some(columns),
                origin,
                height,
                wrap_width,
                value,
                text_runs,
                text_warnings,
                ..
            } = &entity.geometry
            else {
                panic!()
            };
            assert_eq!(*origin, Point2::new(100.0, 200.0));
            assert_eq!(*height, 2.5);
            assert_eq!(*wrap_width, Some(50.0));
            assert_eq!(value, "日本語😀\nالعربية\nবাংলা");
            assert_eq!(columns.count, 3);
            assert_eq!(columns.gutter, 12.5);
            assert!(columns.flow_reversed);
            assert_eq!(columns.manual_breaks, [5, 13]);
            assert_eq!(columns.defined_height, if index == 2 { 0.0 } else { 150.0 });
            assert_eq!(text_runs[0].end, 5);
            assert!(text_warnings.is_empty(), "{text_warnings:?}");
        }
    }

    #[test]
    fn dwg_single_line_literals_and_mtext_controls_remain_distinct() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("literal-text.dwg");
        let mut source = CadDocument::new();
        let literal = r"{中文} \P日本語 \H2;Размер %%%";
        source
            .add_entity(EntityType::Text(Text::with_value(literal, Vector3::ZERO)))
            .unwrap();
        let mut paragraph = acadrust::entities::MText::new();
        paragraph.value = r"{\H2;中文}\P日本語\~120".to_owned();
        paragraph.insertion_point = Vector3::new(0.0, 50.0, 0.0);
        source.add_entity(EntityType::MText(paragraph)).unwrap();
        DwgWriter::write_to_file(&path, &source).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        let opened = DwgAdapter
            .open(
                &bytes,
                "literal-text.dwg",
                Some(&path),
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected 2D scene");
        };
        let values: Vec<_> = scene
            .entities
            .iter()
            .filter_map(|entity| match &entity.geometry {
                Entity2DGeometry::Text { value, .. } => Some(value.as_str()),
                _ => None,
            })
            .collect();
        assert!(values.contains(&r"{中文} \P日本語 \H2;Размер %"));
        assert!(values.contains(&"中文\n日本語\u{a0}120"));
    }

    #[test]
    fn dwg_keeps_scoped_unicode_styles_and_aggregates_fallback_diagnostics() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("scoped-text.dwg");
        let mut source = CadDocument::new();
        let mut paragraph = acadrust::entities::MText::new();
        paragraph.height = 10.0;
        paragraph.value =
            r"A{\fCADView Noto CJK|b1|i1;\H2x;\L中文😀\l}B{\H5;\Oالعربية\o}".to_owned();
        source.add_entity(EntityType::MText(paragraph)).unwrap();
        for y in [50.0, 100.0] {
            let mut unsupported = acadrust::entities::MText::new();
            unsupported.value = r"\W2;日本語".to_owned();
            unsupported.insertion_point = Vector3::new(0.0, y, 0.0);
            source.add_entity(EntityType::MText(unsupported)).unwrap();
        }
        DwgWriter::write_to_file(&path, &source).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        let opened = DwgAdapter
            .open(
                &bytes,
                "scoped-text.dwg",
                Some(&path),
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected 2D scene");
        };
        let labels: Vec<_> = scene
            .entities
            .iter()
            .filter_map(|entity| match &entity.geometry {
                Entity2DGeometry::Text {
                    value,
                    text_runs,
                    text_warnings,
                    ..
                } => Some((value, text_runs, text_warnings)),
                _ => None,
            })
            .collect();
        assert_eq!(labels.len(), 3);
        let (_, runs, warnings) = labels
            .iter()
            .find(|(value, _, _)| value.as_str() == "A中文😀Bالعربية")
            .unwrap();
        assert!(warnings.is_empty());
        assert_eq!(
            runs.iter()
                .map(|run| (run.start, run.end))
                .collect::<Vec<_>>(),
            vec![(0, 1), (1, 5), (5, 6), (6, 13)]
        );
        assert_eq!(
            runs[1].style.font_family.as_deref(),
            Some("CADView Noto CJK")
        );
        assert_eq!(runs[1].style.height_factor, 2.0);
        assert!(runs[1].style.bold && runs[1].style.italic && runs[1].style.underline);
        assert_eq!(runs[2].style, cad_core::TextStyle2D::default());
        assert_eq!(runs[3].style.height_factor, 0.5);
        assert!(runs[3].style.overline);
        assert_eq!(
            labels
                .iter()
                .filter(|(value, _, warnings)| {
                    value.as_str() == "日本語" && !warnings.is_empty()
                })
                .count(),
            2
        );
        let fallbacks: Vec<_> = opened
            .diagnostics
            .iter()
            .filter(|diagnostic| diagnostic.code.starts_with("cad.text."))
            .collect();
        assert_eq!(fallbacks.len(), 1);
        assert_eq!(fallbacks[0].severity, DiagnosticSeverity::Warning);
        assert!(fallbacks[0].message.starts_with("2 text entities"));
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

    #[test]
    fn model_space_unions_owner_entities_when_handle_list_is_partial() {
        let mut source = CadDocument::new();
        source
            .add_entity(EntityType::Line(Line::from_coords(
                0.0, 0.0, 0.0, 10.0, 0.0, 0.0,
            )))
            .unwrap();
        source
            .add_entity(EntityType::Line(Line::from_coords(
                0.0, 10.0, 0.0, 10.0, 10.0, 0.0,
            )))
            .unwrap();
        source
            .block_records
            .get_mut("*Model_Space")
            .unwrap()
            .entity_handles
            .truncate(1);

        let roots = display_roots(&source);
        assert_eq!(roots.entities.len(), 2);
    }

    #[test]
    fn inserted_block_uses_owner_fallback_and_subtracts_base_point() {
        let mut source = CadDocument::new();
        let mut block = BlockRecord::new("OFFSET_PART");
        block.handle = source.allocate_handle();
        block.base_point = Vector3::new(10.0, 20.0, 0.0);
        let block_handle = block.handle;
        source.block_records.add(block).unwrap();

        let mut line = Line::from_coords(11.0, 22.0, 0.0, 14.0, 26.0, 0.0);
        line.common.owner_handle = block_handle;
        source.add_entity(EntityType::Line(line)).unwrap();
        source
            .block_records
            .get_mut("OFFSET_PART")
            .unwrap()
            .entity_handles
            .clear();
        source
            .add_entity(EntityType::Insert(Insert::new(
                "OFFSET_PART",
                Vector3::new(100.0, 200.0, 0.0),
            )))
            .unwrap();

        let opened = build_document(
            source,
            None,
            "offset.dwg",
            "test".to_owned(),
            0,
            &CancellationToken::default(),
            None,
        )
        .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected a 2D scene");
        };
        let (start, end) = scene
            .entities
            .iter()
            .find_map(|entity| match entity.geometry {
                Entity2DGeometry::Line { start, end } => Some((start, end)),
                _ => None,
            })
            .expect("inserted line must be visible");
        assert!((start.x - 101.0).abs() < 1e-6);
        assert!((start.y - 202.0).abs() < 1e-6);
        assert!((end.x - 104.0).abs() < 1e-6);
        assert!((end.y - 206.0).abs() < 1e-6);
    }

    #[test]
    fn tessellates_bulged_polyline_instead_of_drawing_a_chord() {
        let mut polyline = LwPolyline::new();
        polyline.add_point_with_bulge(Vector2::new(0.0, 0.0), 1.0);
        polyline.add_point(Vector2::new(10.0, 0.0));

        let Some(Entity2DGeometry::Polyline { points, .. }) =
            normalize_entity(&EntityType::LwPolyline(polyline), &CadDocument::new())
        else {
            panic!("expected a display polyline");
        };
        assert!(points.len() > 10);
        assert!(points.iter().any(|value| value.y.abs() > 4.9));
        assert!((points.first().unwrap().x - 0.0).abs() < 1e-9);
        assert!((points.last().unwrap().x - 10.0).abs() < 1e-9);
    }

    #[test]
    fn evaluates_quadratic_nurbs_curve() {
        let spline = Spline::from_control_points(
            2,
            vec![
                Vector3::new(0.0, 0.0, 0.0),
                Vector3::new(5.0, 10.0, 0.0),
                Vector3::new(10.0, 0.0, 0.0),
            ],
        );
        let points = tessellate_spline(&spline);
        let midpoint = points[points.len() / 2];
        assert!((midpoint.x - 5.0).abs() < 1e-6);
        assert!((midpoint.y - 5.0).abs() < 1e-6);
        assert_eq!(points.first().copied(), Some(Point2::new(0.0, 0.0)));
        assert_eq!(points.last().copied(), Some(Point2::new(10.0, 0.0)));
    }

    #[test]
    fn keeps_wide_polyline_width_for_rendering() {
        let mut polyline = LwPolyline::new();
        polyline.constant_width = 2.5;
        polyline.add_point(Vector2::new(0.0, 0.0));
        polyline.add_point(Vector2::new(10.0, 0.0));
        assert_eq!(entity_stroke_width(&EntityType::LwPolyline(polyline)), 2.5);
    }

    #[test]
    fn preserves_cad_text_alignment_and_fit_width() {
        let drawing = CadDocument::new();
        let mut centered = Text::with_value("标题", Vector3::new(10.0, 20.0, 0.0));
        centered.alignment_point = Some(Vector3::new(30.0, 40.0, 0.0));
        centered.horizontal_alignment = TextHorizontalAlignment::Center;
        let Some(Entity2DGeometry::Text {
            origin,
            horizontal_alignment,
            ..
        }) = normalize_entity(&EntityType::Text(centered), &drawing)
        else {
            panic!("expected centered text");
        };
        assert_eq!(origin, Point2::new(30.0, 40.0));
        assert!(matches!(
            horizontal_alignment,
            TextHorizontalAlignment2D::Center
        ));

        let mut fitted = Text::with_value("核  定", Vector3::new(1.0, 2.0, 0.0));
        fitted.alignment_point = Some(Vector3::new(11.0, 2.0, 0.0));
        fitted.horizontal_alignment = TextHorizontalAlignment::Fit;
        let Some(Entity2DGeometry::Text {
            origin,
            target_width,
            ..
        }) = normalize_entity(&EntityType::Text(fitted), &drawing)
        else {
            panic!("expected fitted text");
        };
        assert_eq!(origin, Point2::new(1.0, 2.0));
        assert_eq!(target_width, Some(10.0));
    }

    #[test]
    fn exploded_entity_ids_remain_exact_across_json_boundaries() {
        let mut source = CadDocument::new();
        source
            .add_entity(EntityType::Solid(Solid::new(
                Vector3::new(0.0, 0.0, 0.0),
                Vector3::new(10.0, 0.0, 0.0),
                Vector3::new(10.0, 10.0, 0.0),
                Vector3::new(0.0, 10.0, 0.0),
            )))
            .unwrap();
        let opened = build_document(
            source,
            None,
            "solid.dwg",
            "test".to_owned(),
            0,
            &CancellationToken::default(),
            None,
        )
        .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected a 2D scene");
        };
        assert_eq!(scene.entities.len(), 1);
        assert!(scene
            .entities
            .iter()
            .all(|entity| entity.id <= MAX_JSON_SAFE_ENTITY_ID));
        assert!(scene.entities[0].filled);
    }

    #[test]
    fn dimension_uses_anonymous_graphics_without_definition_point_triangles() {
        let mut source = CadDocument::new();
        let mut block = BlockRecord::new("*D_TEST");
        block.handle = source.allocate_handle();
        let block_handle = block.handle;
        source.block_records.add(block).unwrap();

        for (start, end) in [
            ((0.0, 0.0), (0.0, 12.0)),
            ((40.0, 0.0), (40.0, 12.0)),
            ((0.0, 10.0), (40.0, 10.0)),
        ] {
            let mut line = Line::from_coords(start.0, start.1, 0.0, end.0, end.1, 0.0);
            line.common.owner_handle = block_handle;
            source.add_entity(EntityType::Line(line)).unwrap();
        }
        let mut helper = AcadPoint::from_coords(500.0, 500.0, 0.0);
        helper.common.owner_handle = block_handle;
        source.add_entity(EntityType::Point(helper)).unwrap();

        let mut dimension =
            DimensionLinear::new(Vector3::new(0.0, 0.0, 0.0), Vector3::new(40.0, 0.0, 0.0));
        // This definition point would create two long diagonal edges if the
        // dependency's simplified generic explode path were used.
        dimension.definition_point = Vector3::new(500.0, 500.0, 0.0);
        dimension.base.block_name = "*D_TEST".to_owned();
        source
            .add_entity(EntityType::Dimension(Dimension::Linear(dimension)))
            .unwrap();

        let opened = build_document(
            source,
            None,
            "dimension.dwg",
            "test".to_owned(),
            0,
            &CancellationToken::default(),
            None,
        )
        .unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected a 2D scene");
        };
        let lines = scene
            .entities
            .iter()
            .filter_map(|entity| match entity.geometry {
                Entity2DGeometry::Line { start, end } => Some((start, end)),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(lines.len(), 3);
        assert!(scene
            .entities
            .iter()
            .all(|entity| !matches!(entity.geometry, Entity2DGeometry::Point { .. })));
        assert!(lines
            .iter()
            .all(|(start, end)| { (start.x - end.x).hypot(start.y - end.y) < 50.0 }));
        assert_eq!(scene.bounds.unwrap().max, Point2::new(40.0, 12.0));
    }
}
