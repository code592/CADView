use cad_core::{
    distance_2d, distance_3d, Annotation, AnnotationAnchor, AnnotationDocument, AnnotationGeometry,
    Bounds2, CancellationToken, Entity2DGeometry, FormatId, OpenedDocument, Point2, Point3,
    SceneDocument, SceneIndex2D,
};
use once_cell::sync::Lazy;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, AtomicU64, Ordering},
    time::UNIX_EPOCH,
};

static NEXT_SESSION_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_TICKET_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_VIEWPORT_ID: AtomicU64 = AtomicU64::new(1);
static ACTIVE_OPEN_WORKERS: AtomicU64 = AtomicU64::new(0);
static SESSIONS: Lazy<RwLock<HashMap<u64, DocumentSession>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));
static OPEN_TICKETS: Lazy<RwLock<HashMap<u64, OpenTicketState>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));
static CACHE_DIRECTORY: Lazy<RwLock<Option<PathBuf>>> = Lazy::new(|| RwLock::new(None));
static APPLICATION_BACKGROUNDED: AtomicBool = AtomicBool::new(false);
static VIEWPORTS: Lazy<RwLock<HashMap<u64, NativeViewportState>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));

const INITIAL_2D_ENTITY_LIMIT: usize = 75_000;
const VIEWPORT_2D_ENTITY_LIMIT: usize = 150_000;
const SCENE_CACHE_VERSION: u32 = 3;
const DWG_PARSER_VERSION: &str = "acadrust-0.4.1+cadview-3";

struct DocumentSession {
    document: OpenedDocument,
    spatial_index: Option<SceneIndex2D>,
    annotations: AnnotationDocument,
    undo: Vec<Vec<Annotation>>,
    redo: Vec<Vec<Annotation>>,
    camera: CameraState,
}

#[derive(Debug, Clone)]
pub struct FormatInfo {
    pub id: String,
    pub display_name: String,
    pub extensions: Vec<String>,
    pub scene_kind: String,
    pub support_level: String,
    pub available: bool,
    pub can_measure: bool,
    pub note: Option<String>,
}

#[derive(Debug, Clone)]
pub struct OpenDocumentResponse {
    pub session_id: u64,
    pub format_id: String,
    pub scene_kind: String,
    pub display_name: String,
    pub fingerprint: String,
    pub document_json: String,
    pub total_entity_count: u64,
    pub is_partial: bool,
}

#[derive(Debug, Clone)]
pub struct OpenTicket {
    pub ticket_id: u64,
}

#[derive(Debug, Clone)]
pub struct DocumentEventInfo {
    pub kind: String,
    pub stage: String,
    pub progress: f64,
    pub message: Option<String>,
    pub session_id: Option<u64>,
}

struct OpenTicketState {
    cancel: CancellationToken,
    events: VecDeque<DocumentEventInfo>,
    result: Option<Result<OpenDocumentResponse, String>>,
}

struct TicketSceneSink {
    ticket_id: u64,
    emitted_first_frame: bool,
}

impl cad_core::SceneSink for TicketSceneSink {
    fn progress(&mut self, fraction: f32) {
        push_ticket_event(
            self.ticket_id,
            DocumentEventInfo {
                kind: "progress".to_owned(),
                stage: "parsing".to_owned(),
                progress: 0.05 + f64::from(fraction.clamp(0.0, 1.0)) * 0.8,
                message: None,
                session_id: None,
            },
        );
    }

    fn partial(&mut self, _document: &OpenedDocument) {
        if self.emitted_first_frame {
            return;
        }
        self.emitted_first_frame = true;
        push_ticket_event(
            self.ticket_id,
            DocumentEventInfo {
                kind: "first_frame".to_owned(),
                stage: "normalizing".to_owned(),
                progress: 0.85,
                message: None,
                session_id: None,
            },
        );
    }
}

#[derive(Serialize, Deserialize)]
struct SceneCacheEnvelope {
    version: u32,
    parser_version: String,
    source_length: u64,
    source_modified_nanos: u128,
    source_hash: String,
    document: OpenedDocument,
}

#[derive(Debug, Clone, Copy)]
pub struct CameraState {
    pub center_x: f64,
    pub center_y: f64,
    pub center_z: f64,
    pub scale: f64,
    pub yaw: f64,
    pub pitch: f64,
    pub perspective: bool,
}

impl Default for CameraState {
    fn default() -> Self {
        Self {
            center_x: 0.0,
            center_y: 0.0,
            center_z: 0.0,
            scale: 1.0,
            yaw: 0.0,
            pitch: 0.0,
            perspective: false,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ViewportInfo {
    pub viewport_id: u64,
    pub texture_id: i64,
    pub renderer_backend: String,
    pub width: u32,
    pub height: u32,
    pub pixel_ratio: f64,
}

struct NativeViewportState {
    session_id: u64,
    invalidation_generation: u64,
}

#[derive(Debug, Clone)]
pub struct HitResult {
    pub entity_id: u64,
    pub layer_id: u64,
    pub distance: f64,
    pub entity_kind: String,
}

#[derive(Debug, Clone)]
pub struct SnapResult {
    pub entity_id: u64,
    pub x: f64,
    pub y: f64,
    pub snap_kind: String,
    pub distance: f64,
}

#[flutter_rust_bridge::frb(sync)]
pub fn supported_formats() -> Vec<FormatInfo> {
    cad_formats::default_registry()
        .capabilities()
        .into_iter()
        .map(|capability| FormatInfo {
            id: format_id(capability.format),
            display_name: capability.display_name,
            extensions: capability.extensions,
            scene_kind: format!("{:?}", capability.scene_kind).to_ascii_lowercase(),
            support_level: format!("{:?}", capability.support_level).to_ascii_lowercase(),
            available: capability.available,
            can_measure: capability.can_measure,
            note: capability.note,
        })
        .collect()
}

#[flutter_rust_bridge::frb(sync)]
pub fn configure_cache(directory: String) -> Result<(), String> {
    let directory = PathBuf::from(directory);
    std::fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
    *CACHE_DIRECTORY.write() = Some(directory);
    Ok(())
}

fn open_document_internal(
    path: String,
    cancel: &CancellationToken,
    sink: Option<&mut dyn cad_core::SceneSink>,
) -> Result<OpenDocumentResponse, String> {
    cancel.check().map_err(|error| error.to_string())?;
    let source_path = Path::new(&path);
    let document = load_cached_document(source_path).unwrap_or_else(|| {
        let registry = cad_formats::default_registry();
        let document = registry
            .open_path(source_path, cancel, sink)
            .map_err(|error| error.to_string())?;
        cancel.check().map_err(|error| error.to_string())?;
        if !APPLICATION_BACKGROUNDED.load(Ordering::Acquire) {
            write_cached_document(source_path, &document);
        }
        Ok::<OpenedDocument, String>(document)
    })?;
    cancel.check().map_err(|error| error.to_string())?;
    let session_id = NEXT_SESSION_ID.fetch_add(1, Ordering::Relaxed);
    let format_id = format_id(document.metadata.format);
    let scene_kind = scene_kind(&document.scene);
    let display_name = document.metadata.display_name.clone();
    let fingerprint = document.metadata.fingerprint.clone();
    let total_entity_count = match &document.scene {
        SceneDocument::TwoD(scene) => scene.entities.len() as u64,
        _ => 0,
    };
    let spatial_index = match &document.scene {
        SceneDocument::TwoD(scene) => Some(SceneIndex2D::build(scene)),
        _ => None,
    };
    let annotations = AnnotationDocument::new(document.metadata.fingerprint.clone());
    SESSIONS.write().insert(
        session_id,
        DocumentSession {
            document,
            spatial_index,
            annotations,
            undo: Vec::new(),
            redo: Vec::new(),
            camera: CameraState::default(),
        },
    );
    let document_json = serialize_session_document(session_id, None, INITIAL_2D_ENTITY_LIMIT)
        .inspect_err(|_| {
            SESSIONS.write().remove(&session_id);
        })?;
    Ok(OpenDocumentResponse {
        session_id,
        format_id,
        scene_kind,
        display_name,
        fingerprint,
        document_json,
        total_entity_count,
        is_partial: total_entity_count > INITIAL_2D_ENTITY_LIMIT as u64,
    })
}

/// Compatibility wrapper retained for one API version. New UI code should use
/// begin_open_document/poll_document_events/finish_open_document so opening is
/// cancellable and progress never blocks the Dart isolate.
pub fn open_document(path: String) -> Result<OpenDocumentResponse, String> {
    open_document_internal(path, &CancellationToken::default(), None)
}

fn push_ticket_event(ticket_id: u64, event: DocumentEventInfo) {
    if let Some(ticket) = OPEN_TICKETS.write().get_mut(&ticket_id) {
        // Coalesce parser progress so a large file cannot grow this queue
        // without bound when Dart is temporarily backgrounded.
        if event.kind == "progress"
            && ticket
                .events
                .back()
                .is_some_and(|previous| previous.kind == "progress")
        {
            ticket.events.pop_back();
        }
        ticket.events.push_back(event);
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn begin_open_document(path: String) -> Result<OpenTicket, String> {
    if APPLICATION_BACKGROUNDED.load(Ordering::Acquire) {
        return Err("cannot begin opening a document while the app is backgrounded".to_owned());
    }
    let previous_workers = ACTIVE_OPEN_WORKERS.fetch_add(1, Ordering::AcqRel);
    if previous_workers >= 2 {
        ACTIVE_OPEN_WORKERS.fetch_sub(1, Ordering::AcqRel);
        return Err("at most two document workers may run concurrently".to_owned());
    }
    let ticket_id = NEXT_TICKET_ID.fetch_add(1, Ordering::Relaxed);
    let cancel = CancellationToken::default();
    OPEN_TICKETS.write().insert(
        ticket_id,
        OpenTicketState {
            cancel: cancel.clone(),
            events: VecDeque::from([DocumentEventInfo {
                kind: "progress".to_owned(),
                stage: "probing".to_owned(),
                progress: 0.01,
                message: None,
                session_id: None,
            }]),
            result: None,
        },
    );
    std::thread::Builder::new()
        .name("cad-open".to_owned())
        .spawn(move || {
            let mut sink = TicketSceneSink {
                ticket_id,
                emitted_first_frame: false,
            };
            let result = open_document_internal(path, &cancel, Some(&mut sink));
            let event = match &result {
                Ok(response) => DocumentEventInfo {
                    kind: "complete".to_owned(),
                    stage: "complete".to_owned(),
                    progress: 1.0,
                    message: None,
                    session_id: Some(response.session_id),
                },
                Err(message) if cancel.is_cancelled() => DocumentEventInfo {
                    kind: "cancelled".to_owned(),
                    stage: "cancelled".to_owned(),
                    progress: 1.0,
                    message: Some(message.clone()),
                    session_id: None,
                },
                Err(message) => DocumentEventInfo {
                    kind: "diagnostic".to_owned(),
                    stage: "failed".to_owned(),
                    progress: 1.0,
                    message: Some(message.clone()),
                    session_id: None,
                },
            };
            let mut tickets = OPEN_TICKETS.write();
            if let Some(ticket) = tickets.get_mut(&ticket_id) {
                ticket.events.push_back(event);
                ticket.result = Some(result);
            } else if let Ok(response) = result {
                close_document(response.session_id);
            }
            ACTIVE_OPEN_WORKERS.fetch_sub(1, Ordering::AcqRel);
        })
        .map_err(|error| {
            ACTIVE_OPEN_WORKERS.fetch_sub(1, Ordering::AcqRel);
            OPEN_TICKETS.write().remove(&ticket_id);
            error.to_string()
        })?;
    Ok(OpenTicket { ticket_id })
}

#[flutter_rust_bridge::frb(sync)]
pub fn poll_document_events(ticket_id: u64) -> Result<Vec<DocumentEventInfo>, String> {
    let mut tickets = OPEN_TICKETS.write();
    let ticket = tickets
        .get_mut(&ticket_id)
        .ok_or_else(|| "unknown open ticket".to_owned())?;
    Ok(ticket.events.drain(..).collect())
}

#[flutter_rust_bridge::frb(sync)]
pub fn cancel_open_document(ticket_id: u64) -> bool {
    let tickets = OPEN_TICKETS.read();
    let Some(ticket) = tickets.get(&ticket_id) else {
        return false;
    };
    ticket.cancel.cancel();
    true
}

pub fn finish_open_document(ticket_id: u64) -> Result<Option<OpenDocumentResponse>, String> {
    let mut tickets = OPEN_TICKETS.write();
    let Some(ticket) = tickets.get_mut(&ticket_id) else {
        return Err("unknown open ticket".to_owned());
    };
    let Some(result) = ticket.result.take() else {
        return Ok(None);
    };
    tickets.remove(&ticket_id);
    result.map(Some)
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_application_backgrounded(backgrounded: bool) {
    APPLICATION_BACKGROUNDED.store(backgrounded, Ordering::Release);
    if backgrounded {
        for ticket in OPEN_TICKETS.read().values() {
            ticket.cancel.cancel();
        }
    }
}

fn serialize_session_document(
    session_id: u64,
    viewport: Option<Bounds2>,
    limit: usize,
) -> Result<String, String> {
    let sessions = SESSIONS.read();
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?;
    let scene = match &session.document.scene {
        SceneDocument::TwoD(source) => {
            let visible_layers = source
                .layers
                .iter()
                .filter(|layer| layer.visible)
                .map(|layer| layer.id)
                .collect::<HashSet<_>>();
            let candidates = viewport.and_then(|bounds| {
                session
                    .spatial_index
                    .as_ref()
                    .map(|index| index.query(bounds).into_iter().collect::<HashSet<_>>())
            });
            let filtered = source.entities.iter().filter(|entity| {
                visible_layers.contains(&entity.layer_id)
                    && candidates
                        .as_ref()
                        .is_none_or(|ids| ids.contains(&entity.id))
            });
            let entities = if limit == 0 {
                Vec::new()
            } else {
                let selected = filtered.collect::<Vec<_>>();
                if selected.len() <= limit {
                    selected.into_iter().cloned().collect()
                } else {
                    let stride = selected.len().div_ceil(limit);
                    selected
                        .into_iter()
                        .step_by(stride)
                        .take(limit)
                        .cloned()
                        .collect()
                }
            };
            SceneDocument::TwoD(cad_core::Scene2D {
                layers: source.layers.clone(),
                entities,
                bounds: source.bounds,
            })
        }
        // The retained viewport conversion is currently targeted at the large
        // 2D CAD path. Existing 3D/PDF behaviour remains compatible.
        other => other.clone(),
    };
    serde_json::to_string(&OpenedDocument {
        metadata: session.document.metadata.clone(),
        scene,
        diagnostics: session.document.diagnostics.clone(),
    })
    .map_err(|error| error.to_string())
}

fn empty_bounds() -> Bounds2 {
    Bounds2 {
        min: Point2::new(0.0, 0.0),
        max: Point2::new(0.0, 0.0),
    }
}

fn source_state(path: &Path) -> Option<(u64, u128)> {
    let metadata = std::fs::metadata(path).ok()?;
    let modified = metadata
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()?
        .as_nanos();
    Some((metadata.len(), modified))
}

fn scene_cache_path(path: &Path) -> Option<PathBuf> {
    let directory = CACHE_DIRECTORY.read().clone()?;
    let key = blake3::hash(path.to_string_lossy().as_bytes()).to_hex();
    Some(directory.join(format!("{key}.scene.bin")))
}

fn load_cached_document(path: &Path) -> Option<Result<OpenedDocument, String>> {
    let cache_path = scene_cache_path(path)?;
    let (source_length, source_modified_nanos) = source_state(path)?;
    let bytes = std::fs::read(&cache_path).ok()?;
    let envelope = match ciborium::from_reader::<SceneCacheEnvelope, _>(bytes.as_slice()) {
        Ok(envelope) => envelope,
        Err(_) => {
            let _ = std::fs::remove_file(cache_path);
            return None;
        }
    };
    if envelope.version != SCENE_CACHE_VERSION
        || envelope.parser_version != DWG_PARSER_VERSION
        || envelope.source_length != source_length
        || envelope.source_modified_nanos != source_modified_nanos
    {
        let _ = std::fs::remove_file(cache_path);
        return None;
    }
    let source_hash = match cad_core::fingerprint_path(path) {
        Ok(hash) => hash,
        Err(error) => return Some(Err(error.to_string())),
    };
    if envelope.source_hash != source_hash {
        let _ = std::fs::remove_file(cache_path);
        return None;
    }
    Some(Ok(envelope.document))
}

fn write_cached_document(path: &Path, document: &OpenedDocument) {
    // DWG normalization is currently the expensive cache target. Avoid
    // duplicating the already fast lightweight adapters on disk.
    if document.metadata.format != FormatId::Dwg {
        return;
    }
    let Some(cache_path) = scene_cache_path(path) else {
        return;
    };
    let Some((source_length, source_modified_nanos)) = source_state(path) else {
        return;
    };
    let envelope = SceneCacheEnvelope {
        version: SCENE_CACHE_VERSION,
        parser_version: DWG_PARSER_VERSION.to_owned(),
        source_length,
        source_modified_nanos,
        source_hash: document.metadata.fingerprint.clone(),
        document: document.clone(),
    };
    let mut bytes = Vec::new();
    if ciborium::into_writer(&envelope, &mut bytes).is_err() {
        return;
    }
    let temporary_path = cache_path.with_extension("scene.bin.tmp");
    if std::fs::write(&temporary_path, bytes).is_ok() {
        let _ = std::fs::rename(temporary_path, cache_path);
    }
}

pub fn document_summary(session_id: u64) -> Result<String, String> {
    serialize_session_document(session_id, Some(empty_bounds()), 0)
}

pub fn viewport_document(
    session_id: u64,
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,
) -> Result<String, String> {
    if ![min_x, min_y, max_x, max_y]
        .iter()
        .all(|value| value.is_finite())
    {
        return Err("viewport bounds must be finite".to_owned());
    }
    serialize_session_document(
        session_id,
        Some(Bounds2 {
            min: Point2::new(min_x.min(max_x), min_y.min(max_y)),
            max: Point2::new(min_x.max(max_x), min_y.max(max_y)),
        }),
        VIEWPORT_2D_ENTITY_LIMIT,
    )
}

#[flutter_rust_bridge::frb(sync)]
pub fn close_document(session_id: u64) -> bool {
    VIEWPORTS
        .write()
        .retain(|_, viewport| viewport.session_id != session_id);
    SESSIONS.write().remove(&session_id).is_some()
}

#[flutter_rust_bridge::frb(sync)]
pub fn create_viewport(
    session_id: u64,
    width: u32,
    height: u32,
    pixel_ratio: f64,
) -> Result<ViewportInfo, String> {
    if !SESSIONS.read().contains_key(&session_id) {
        return Err("unknown session".to_owned());
    }
    let viewport_id = NEXT_VIEWPORT_ID.fetch_add(1, Ordering::Relaxed);
    VIEWPORTS.write().insert(
        viewport_id,
        NativeViewportState {
            session_id,
            invalidation_generation: 1,
        },
    );
    Ok(ViewportInfo {
        viewport_id,
        texture_id: -1,
        renderer_backend: "flutter_vector_preview".to_owned(),
        width,
        height,
        pixel_ratio,
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn close_viewport(viewport_id: u64) -> bool {
    VIEWPORTS.write().remove(&viewport_id).is_some()
}

fn invalidate_session_viewports(session_id: u64) {
    for viewport in VIEWPORTS.write().values_mut() {
        if viewport.session_id == session_id {
            viewport.invalidation_generation = viewport.invalidation_generation.wrapping_add(1);
        }
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn update_camera(session_id: u64, camera: CameraState) -> Result<(), String> {
    let mut sessions = SESSIONS.write();
    let session = sessions
        .get_mut(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?;
    session.camera = camera;
    drop(sessions);
    invalidate_session_viewports(session_id);
    Ok(())
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_visibility(session_id: u64, item_id: u64, visible: bool) -> Result<String, String> {
    let mut sessions = SESSIONS.write();
    let session = sessions
        .get_mut(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?;
    match &mut session.document.scene {
        SceneDocument::TwoD(scene) => {
            let layer = scene
                .layers
                .iter_mut()
                .find(|layer| layer.id == item_id)
                .ok_or_else(|| "unknown layer".to_owned())?;
            layer.visible = visible;
        }
        SceneDocument::ThreeD(scene) => {
            if !set_node_visibility(&mut scene.root_nodes, item_id, visible) {
                return Err("unknown assembly node".to_owned());
            }
        }
        SceneDocument::Paged(_) => return Err("paged documents have no visibility tree".to_owned()),
    }
    drop(sessions);
    invalidate_session_viewports(session_id);
    serialize_session_document(session_id, None, INITIAL_2D_ENTITY_LIMIT)
}

#[flutter_rust_bridge::frb(sync)]
pub fn hit_test(
    session_id: u64,
    x: f64,
    y: f64,
    tolerance: f64,
) -> Result<Option<HitResult>, String> {
    let sessions = SESSIONS.read();
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?;
    let SceneDocument::TwoD(scene) = &session.document.scene else {
        return Ok(None);
    };
    let target = Point2::new(x, y);
    let tolerance = tolerance.abs();
    let candidates = spatial_candidates(session, target, tolerance);
    Ok(scene
        .entities
        .iter()
        .filter(|entity| candidates.contains(&entity.id))
        .filter(|entity| {
            scene
                .layers
                .iter()
                .find(|layer| layer.id == entity.layer_id)
                .is_none_or(|layer| layer.visible)
        })
        .filter_map(|entity| {
            entity_distance(&entity.geometry, target).map(|distance| (entity, distance))
        })
        .filter(|(_, distance)| *distance <= tolerance)
        .min_by(|(_, a), (_, b)| a.total_cmp(b))
        .map(|(entity, distance)| HitResult {
            entity_id: entity.id,
            layer_id: entity.layer_id,
            distance,
            entity_kind: entity_kind(&entity.geometry).to_owned(),
        }))
}

#[flutter_rust_bridge::frb(sync)]
pub fn snap(session_id: u64, x: f64, y: f64, tolerance: f64) -> Result<Option<SnapResult>, String> {
    let sessions = SESSIONS.read();
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?;
    let SceneDocument::TwoD(scene) = &session.document.scene else {
        return Ok(None);
    };
    let target = Point2::new(x, y);
    let tolerance = tolerance.abs();
    let candidates = spatial_candidates(session, target, tolerance);
    Ok(scene
        .entities
        .iter()
        .filter(|entity| candidates.contains(&entity.id))
        .flat_map(|entity| snap_points(entity.id, &entity.geometry))
        .map(|(entity_id, point, kind)| (entity_id, point, kind, distance_2d(target, point)))
        .filter(|(_, _, _, distance)| *distance <= tolerance)
        .min_by(|(_, _, _, a), (_, _, _, b)| a.total_cmp(b))
        .map(|(entity_id, point, kind, distance)| SnapResult {
            entity_id,
            x: point.x,
            y: point.y,
            snap_kind: kind,
            distance,
        }))
}

fn spatial_candidates(
    session: &DocumentSession,
    target: Point2,
    tolerance: f64,
) -> std::collections::HashSet<u64> {
    session
        .spatial_index
        .as_ref()
        .map(|index| {
            index
                .query(Bounds2 {
                    min: Point2::new(target.x - tolerance, target.y - tolerance),
                    max: Point2::new(target.x + tolerance, target.y + tolerance),
                })
                .into_iter()
                .collect()
        })
        .unwrap_or_default()
}

#[flutter_rust_bridge::frb(sync)]
pub fn measure_distance_2d(x1: f64, y1: f64, x2: f64, y2: f64) -> f64 {
    distance_2d(Point2::new(x1, y1), Point2::new(x2, y2))
}

#[flutter_rust_bridge::frb(sync)]
pub fn measure_distance_3d(x1: f64, y1: f64, z1: f64, x2: f64, y2: f64, z2: f64) -> f64 {
    distance_3d(Point3::new(x1, y1, z1), Point3::new(x2, y2, z2))
}

#[flutter_rust_bridge::frb(sync)]
pub fn annotation_command(session_id: u64, annotation_json: String) -> Result<String, String> {
    let annotation: Annotation =
        serde_json::from_str(&annotation_json).map_err(|error| error.to_string())?;
    apply_annotation(session_id, annotation)
}

#[flutter_rust_bridge::frb(sync)]
pub fn add_text_annotation(
    session_id: u64,
    value: String,
    x: f64,
    y: f64,
    entity_id: Option<u64>,
) -> Result<String, String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| error.to_string())?
        .as_millis()
        .min(i64::MAX as u128) as i64;
    apply_annotation(
        session_id,
        Annotation {
            id: uuid::Uuid::new_v4(),
            author: None,
            color_argb: 0xffffcc00,
            geometry: AnnotationGeometry::Text {
                anchor: AnnotationAnchor {
                    entity_path: entity_id.map(|id| format!("entity/{id}")),
                    local_parameter: None,
                    world_2d: Some(Point2::new(x, y)),
                    world_3d: None,
                },
                value,
            },
            created_at_epoch_ms: now,
            updated_at_epoch_ms: now,
        },
    )
}

#[flutter_rust_bridge::frb(sync)]
pub fn add_text_annotation_3d(
    session_id: u64,
    value: String,
    x: f64,
    y: f64,
    z: f64,
    mesh_id: Option<u64>,
) -> Result<String, String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| error.to_string())?
        .as_millis()
        .min(i64::MAX as u128) as i64;
    apply_annotation(
        session_id,
        Annotation {
            id: uuid::Uuid::new_v4(),
            author: None,
            color_argb: 0xffffcc00,
            geometry: AnnotationGeometry::Text {
                anchor: AnnotationAnchor {
                    entity_path: mesh_id.map(|id| format!("mesh/{id}")),
                    local_parameter: None,
                    world_2d: None,
                    world_3d: Some(Point3::new(x, y, z)),
                },
                value,
            },
            created_at_epoch_ms: now,
            updated_at_epoch_ms: now,
        },
    )
}

#[flutter_rust_bridge::frb(sync)]
pub fn delete_annotation(session_id: u64, annotation_id: String) -> Result<String, String> {
    let annotation_id = uuid::Uuid::parse_str(&annotation_id).map_err(|error| error.to_string())?;
    let mut sessions = SESSIONS.write();
    let session = sessions
        .get_mut(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?;
    let index = session
        .annotations
        .annotations
        .iter()
        .position(|annotation| annotation.id == annotation_id)
        .ok_or_else(|| "unknown annotation".to_owned())?;
    session.undo.push(session.annotations.annotations.clone());
    session.redo.clear();
    session.annotations.annotations.remove(index);
    session
        .annotations
        .to_json()
        .map_err(|error| error.to_string())
}

#[flutter_rust_bridge::frb(sync)]
pub fn undo(session_id: u64) -> Result<String, String> {
    move_history(session_id, true)
}

#[flutter_rust_bridge::frb(sync)]
pub fn redo(session_id: u64) -> Result<String, String> {
    move_history(session_id, false)
}

#[flutter_rust_bridge::frb(sync)]
pub fn export_annotations(session_id: u64) -> Result<String, String> {
    let sessions = SESSIONS.read();
    sessions
        .get(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?
        .annotations
        .to_json()
        .map_err(|error| error.to_string())
}

#[flutter_rust_bridge::frb(sync)]
pub fn save_annotations(session_id: u64, database_path: String) -> Result<(), String> {
    let document = SESSIONS
        .read()
        .get(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?
        .annotations
        .clone();
    let mut store = cad_storage::AnnotationStore::open(std::path::Path::new(&database_path))
        .map_err(|error| error.to_string())?;
    store
        .replace_document(&document)
        .map_err(|error| error.to_string())
}

#[flutter_rust_bridge::frb(sync)]
pub fn load_annotations(session_id: u64, database_path: String) -> Result<String, String> {
    let fingerprint = SESSIONS
        .read()
        .get(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?
        .document
        .metadata
        .fingerprint
        .clone();
    let store = cad_storage::AnnotationStore::open(std::path::Path::new(&database_path))
        .map_err(|error| error.to_string())?;
    let document = store
        .load_document(&fingerprint)
        .map_err(|error| error.to_string())?;
    let json = document.to_json().map_err(|error| error.to_string())?;
    let mut sessions = SESSIONS.write();
    let session = sessions
        .get_mut(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?;
    session.annotations = document;
    session.undo.clear();
    session.redo.clear();
    Ok(json)
}

fn move_history(session_id: u64, undo: bool) -> Result<String, String> {
    let mut sessions = SESSIONS.write();
    let session = sessions
        .get_mut(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?;
    let next = if undo {
        session.undo.pop()
    } else {
        session.redo.pop()
    };
    if let Some(next) = next {
        let current = std::mem::replace(&mut session.annotations.annotations, next);
        if undo {
            session.redo.push(current);
        } else {
            session.undo.push(current);
        }
    }
    session
        .annotations
        .to_json()
        .map_err(|error| error.to_string())
}

fn apply_annotation(session_id: u64, annotation: Annotation) -> Result<String, String> {
    let mut sessions = SESSIONS.write();
    let session = sessions
        .get_mut(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?;
    session.undo.push(session.annotations.annotations.clone());
    session.redo.clear();
    if let Some(existing) = session
        .annotations
        .annotations
        .iter_mut()
        .find(|value| value.id == annotation.id)
    {
        *existing = annotation;
    } else {
        session.annotations.annotations.push(annotation);
    }
    session
        .annotations
        .to_json()
        .map_err(|error| error.to_string())
}

fn set_node_visibility(nodes: &mut [cad_core::AssemblyNode], id: u64, visible: bool) -> bool {
    for node in nodes {
        if node.id == id {
            node.visible = visible;
            return true;
        }
        if set_node_visibility(&mut node.children, id, visible) {
            return true;
        }
    }
    false
}

fn entity_distance(geometry: &Entity2DGeometry, target: Point2) -> Option<f64> {
    match geometry {
        Entity2DGeometry::Point { position } => Some(distance_2d(*position, target)),
        Entity2DGeometry::Line { start, end } => Some(point_segment_distance(target, *start, *end)),
        Entity2DGeometry::Polyline { points, closed } => {
            let mut best = points
                .windows(2)
                .map(|segment| point_segment_distance(target, segment[0], segment[1]))
                .reduce(f64::min);
            if *closed && points.len() > 2 {
                best = Some(best.unwrap_or(f64::INFINITY).min(point_segment_distance(
                    target,
                    *points.last()?,
                    points[0],
                )));
            }
            best
        }
        Entity2DGeometry::Circle { center, radius }
        | Entity2DGeometry::Arc { center, radius, .. } => {
            Some((distance_2d(*center, target) - radius).abs())
        }
        Entity2DGeometry::Text { origin, .. } => Some(distance_2d(*origin, target)),
    }
}

fn point_segment_distance(point: Point2, start: Point2, end: Point2) -> f64 {
    let dx = end.x - start.x;
    let dy = end.y - start.y;
    let length_sq = dx * dx + dy * dy;
    if length_sq == 0.0 {
        return distance_2d(point, start);
    }
    let t = (((point.x - start.x) * dx + (point.y - start.y) * dy) / length_sq).clamp(0.0, 1.0);
    distance_2d(point, Point2::new(start.x + t * dx, start.y + t * dy))
}

fn snap_points(entity_id: u64, geometry: &Entity2DGeometry) -> Vec<(u64, Point2, String)> {
    match geometry {
        Entity2DGeometry::Point { position } => vec![(entity_id, *position, "point".to_owned())],
        Entity2DGeometry::Line { start, end } => vec![
            (entity_id, *start, "endpoint".to_owned()),
            (entity_id, *end, "endpoint".to_owned()),
            (
                entity_id,
                Point2::new((start.x + end.x) / 2.0, (start.y + end.y) / 2.0),
                "midpoint".to_owned(),
            ),
        ],
        Entity2DGeometry::Polyline { points, .. } => points
            .iter()
            .copied()
            .map(|point| (entity_id, point, "vertex".to_owned()))
            .collect(),
        Entity2DGeometry::Circle { center, .. } | Entity2DGeometry::Arc { center, .. } => {
            vec![(entity_id, *center, "center".to_owned())]
        }
        Entity2DGeometry::Text { origin, .. } => vec![(entity_id, *origin, "insertion".to_owned())],
    }
}

fn entity_kind(geometry: &Entity2DGeometry) -> &'static str {
    match geometry {
        Entity2DGeometry::Point { .. } => "point",
        Entity2DGeometry::Line { .. } => "line",
        Entity2DGeometry::Polyline { .. } => "polyline",
        Entity2DGeometry::Circle { .. } => "circle",
        Entity2DGeometry::Arc { .. } => "arc",
        Entity2DGeometry::Text { .. } => "text",
    }
}

fn format_id(format: FormatId) -> String {
    format!("{format:?}").to_ascii_lowercase()
}

fn scene_kind(scene: &SceneDocument) -> String {
    match scene {
        SceneDocument::TwoD(_) => "two_d",
        SceneDocument::ThreeD(_) => "three_d",
        SceneDocument::Paged(_) => "paged",
    }
    .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use cad_core::{DocumentMetadata, Entity2D, Scene2D};

    #[test]
    fn format_registry_is_exposed() {
        let formats = supported_formats();
        assert!(formats
            .iter()
            .any(|format| format.id == "dxf" && format.available));
        assert!(formats.iter().any(|format| {
            format.id == "dwg" && format.available && format.support_level == "beta"
        }));
    }

    #[test]
    fn viewport_serialization_uses_spatial_index() {
        let session_id = u64::MAX - 1;
        let mut scene = Scene2D {
            layers: vec![cad_core::Layer {
                id: 1,
                name: "0".to_owned(),
                visible: true,
                color_argb: 0xffffffff,
            }],
            entities: vec![
                Entity2D {
                    id: 1,
                    layer_id: 1,
                    color_argb: 0xffffffff,
                    geometry: Entity2DGeometry::Point {
                        position: Point2::new(1.0, 1.0),
                    },
                },
                Entity2D {
                    id: 2,
                    layer_id: 1,
                    color_argb: 0xffffffff,
                    geometry: Entity2DGeometry::Point {
                        position: Point2::new(100.0, 100.0),
                    },
                },
            ],
            bounds: None,
        };
        scene.recompute_bounds();
        let document = OpenedDocument {
            metadata: DocumentMetadata {
                format: FormatId::Dxf,
                display_name: "viewport.dxf".to_owned(),
                fingerprint: "test".to_owned(),
                byte_length: 0,
                units: None,
                author: None,
            },
            scene: SceneDocument::TwoD(scene.clone()),
            diagnostics: Vec::new(),
        };
        SESSIONS.write().insert(
            session_id,
            DocumentSession {
                document,
                spatial_index: Some(SceneIndex2D::build(&scene)),
                annotations: AnnotationDocument::new("test".to_owned()),
                undo: Vec::new(),
                redo: Vec::new(),
                camera: CameraState::default(),
            },
        );

        let json = viewport_document(session_id, 0.0, 0.0, 10.0, 10.0).unwrap();
        let opened: OpenedDocument = serde_json::from_str(&json).unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected 2D scene");
        };
        assert_eq!(scene.entities.len(), 1);
        assert_eq!(scene.entities[0].id, 1);
        close_document(session_id);
    }

    #[test]
    fn dwg_cache_validates_content_hash_and_discards_corruption() {
        let directory = tempfile::tempdir().unwrap();
        configure_cache(
            directory
                .path()
                .join("cache")
                .to_string_lossy()
                .into_owned(),
        )
        .unwrap();
        let source_path = directory.path().join("drawing.dwg");
        std::fs::write(&source_path, b"AC1032 cache fixture").unwrap();
        let document = OpenedDocument {
            metadata: DocumentMetadata {
                format: FormatId::Dwg,
                display_name: "drawing.dwg".to_owned(),
                fingerprint: cad_core::fingerprint_path(&source_path).unwrap(),
                byte_length: std::fs::metadata(&source_path).unwrap().len(),
                units: None,
                author: None,
            },
            scene: SceneDocument::TwoD(Scene2D::default()),
            diagnostics: Vec::new(),
        };

        write_cached_document(&source_path, &document);
        let cached = load_cached_document(&source_path)
            .expect("cache entry")
            .expect("valid cache");
        assert_eq!(cached.metadata.fingerprint, document.metadata.fingerprint);

        let cache_path = scene_cache_path(&source_path).unwrap();
        std::fs::write(&cache_path, b"not a cache envelope").unwrap();
        assert!(load_cached_document(&source_path).is_none());
        assert!(!cache_path.exists());
    }

    #[test]
    fn asynchronous_open_emits_terminal_event_and_returns_session() {
        set_application_backgrounded(false);
        let directory = tempfile::tempdir().unwrap();
        let source_path = directory.path().join("drawing.svg");
        std::fs::write(
            &source_path,
            br#"<svg xmlns="http://www.w3.org/2000/svg"><line x1="0" y1="0" x2="10" y2="10"/></svg>"#,
        )
        .unwrap();
        let ticket = begin_open_document(source_path.to_string_lossy().into_owned()).unwrap();
        let mut terminal = false;
        for _ in 0..200 {
            let events = poll_document_events(ticket.ticket_id).unwrap();
            terminal |= events
                .iter()
                .any(|event| event.kind == "complete" || event.stage == "failed");
            if terminal {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert!(terminal, "asynchronous open did not reach a terminal event");
        let response = finish_open_document(ticket.ticket_id)
            .unwrap()
            .expect("completed response");
        assert_eq!(response.format_id, "svg");
        assert!(close_document(response.session_id));
    }
}
