use cad_core::TextGeometry2D;
use cad_core::{
    distance_2d, distance_3d, simple_polygon_area, Annotation, AnnotationAnchor,
    AnnotationDocument, AnnotationGeometry, Bounds2, CancellationToken, Entity2DGeometry, FormatId,
    OpenedDocument, Point2, Point3, SceneDocument, SceneIndex2D,
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

const INITIAL_2D_ENTITY_LIMIT: usize = 250_000;
// Version 12 includes validated per-mesh volume centroid coordinates.
const SCENE_CACHE_VERSION: u32 = 32;
const DWG_PARSER_VERSION: &str = "acadrust-0.4.1+cadview-17";

struct DocumentSession {
    document: OpenedDocument,
    spatial_index: Option<SceneIndex2D>,
    spatial_index_3d: Option<cad_core::SceneIndex3D>,
    text_layout_bounds: HashMap<u64, Bounds2>,
    entity_kind_counts: HashMap<String, u64>,
    layer_entity_kind_counts: HashMap<(u64, String), u64>,
    entity_kind_lengths: HashMap<String, f64>,
    layer_entity_kind_lengths: HashMap<(u64, String), f64>,
    entity_kind_areas: HashMap<String, f64>,
    layer_entity_kind_areas: HashMap<(u64, String), f64>,
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
pub struct VisibilityChange {
    pub item_id: u64,
    pub visible: bool,
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

/// Scene cache file: [CACHE_MAGIC], then length-prefixed CBOR blobs. The
/// first is a [SceneCacheHeader]; the 2D entities follow in separate
/// chunks, so a stale cache is rejected after reading the small header and
/// a valid one is decoded on several threads.
const CACHE_MAGIC: &[u8; 8] = b"CVSCENE2";

#[derive(Deserialize)]
struct SceneCacheHeader {
    version: u32,
    parser_version: String,
    source_length: u64,
    source_modified_nanos: u128,
    source_hash: String,
    metadata: cad_core::DocumentMetadata,
    diagnostics: Vec<cad_core::FormatDiagnostic>,
    scene: CachedScene,
    entity_chunks: u32,
}

#[derive(Serialize)]
struct SceneCacheHeaderRef<'a> {
    version: u32,
    parser_version: &'a str,
    source_length: u64,
    source_modified_nanos: u128,
    source_hash: &'a str,
    metadata: &'a cad_core::DocumentMetadata,
    diagnostics: &'a [cad_core::FormatDiagnostic],
    scene: CachedSceneRef<'a>,
    entity_chunks: u32,
}

/// The scene without its 2D entities, which are stored in chunks.
#[derive(Deserialize)]
enum CachedScene {
    TwoD {
        layers: Vec<cad_core::Layer>,
        bounds: Option<Bounds2>,
    },
    Other(SceneDocument),
}

#[derive(Serialize)]
enum CachedSceneRef<'a> {
    TwoD {
        layers: &'a [cad_core::Layer],
        bounds: Option<Bounds2>,
    },
    Other(&'a SceneDocument),
}

/// Threads used to encode/decode cache chunks and similar bulk work.
fn worker_threads() -> usize {
    std::thread::available_parallelism()
        .map(|threads| threads.get())
        .unwrap_or(1)
        .clamp(1, 8)
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

#[derive(Debug, Clone)]
pub struct EntityCountSummary {
    pub entity_kind: String,
    pub layer_id: u64,
    pub same_kind_in_layer: u64,
    pub same_kind_in_document: u64,
    pub same_kind_length_in_layer: Option<f64>,
    pub same_kind_length_in_document: Option<f64>,
    pub same_kind_area_in_layer: Option<f64>,
    pub same_kind_area_in_document: Option<f64>,
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
    compact: bool,
) -> Result<OpenDocumentResponse, String> {
    cancel.check().map_err(|error| error.to_string())?;
    let source_path = Path::new(&path);
    let cached = load_cached_document(source_path);
    let write_cache = cached.is_none() && !APPLICATION_BACKGROUNDED.load(Ordering::Acquire);
    let document = cached.unwrap_or_else(|| {
        let registry = cad_formats::default_registry();
        let mut document = registry
            .open_path(source_path, cancel, sink)
            .map_err(|error| error.to_string())?;
        if let SceneDocument::TwoD(scene) = &document.scene {
            document.metadata.frames = cad_core::detect_drawing_frames(scene);
        }
        cancel.check().map_err(|error| error.to_string())?;
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
    // The indexes, statistics and cache file only read the document; build
    // them side by side rather than one after another.
    let (spatial_index, spatial_index_3d, statistics) = std::thread::scope(|scope| {
        let cache =
            write_cache.then(|| scope.spawn(|| write_cached_document(source_path, &document)));
        let index = scope.spawn(|| match &document.scene {
            SceneDocument::TwoD(scene) => (Some(SceneIndex2D::build(scene)), None),
            SceneDocument::ThreeD(scene) => (None, Some(cad_core::SceneIndex3D::build(scene))),
            _ => (None, None),
        });
        let statistics = build_entity_statistics(&document);
        let (index_2d, index_3d) = index.join().unwrap_or((None, None));
        if let Some(cache) = cache {
            let _ = cache.join();
        }
        (index_2d, index_3d, statistics)
    });
    let spatial_index = match (&document.scene, spatial_index) {
        (SceneDocument::TwoD(scene), None) => Some(SceneIndex2D::build(scene)),
        (_, index) => index,
    };
    let annotations = AnnotationDocument::new(document.metadata.fingerprint.clone());
    let (
        entity_kind_counts,
        layer_entity_kind_counts,
        entity_kind_lengths,
        layer_entity_kind_lengths,
        entity_kind_areas,
        layer_entity_kind_areas,
    ) = statistics;
    SESSIONS.write().insert(
        session_id,
        DocumentSession {
            document,
            spatial_index,
            spatial_index_3d,
            text_layout_bounds: HashMap::new(),
            entity_kind_counts,
            layer_entity_kind_counts,
            entity_kind_lengths,
            layer_entity_kind_lengths,
            entity_kind_areas,
            layer_entity_kind_areas,
            annotations,
            undo: Vec::new(),
            redo: Vec::new(),
            camera: CameraState::default(),
        },
    );
    // A large initial scene is returned as metadata only and immediately
    // replaced by an exact spatial-index viewport query in Flutter. Never
    // stride-sample CAD entities: a sampled preview can remove dimensions,
    // borders or block details and therefore misrepresent the drawing.
    let include_initial_entities = total_entity_count <= INITIAL_2D_ENTITY_LIMIT as u64 && !compact;
    let document_json = serialize_session_document(session_id, None, include_initial_entities)
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
    open_document_internal(path, &CancellationToken::default(), None, false)
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
    begin_open_document_impl(path, false)
}

/// Metadata-first open; the UI fetches lossless packed geometry (2D after
/// text-envelope refinement). The legacy JSON open APIs remain compatible.
#[flutter_rust_bridge::frb(sync)]
pub fn begin_open_document_compact(path: String) -> Result<OpenTicket, String> {
    begin_open_document_impl(path, true)
}

fn begin_open_document_impl(path: String, compact: bool) -> Result<OpenTicket, String> {
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
            let result = open_document_internal(path, &cancel, Some(&mut sink), compact);
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
    include_2d_entities: bool,
) -> Result<String, String> {
    let sessions = SESSIONS.read();
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?;
    serialize_session_view(session, viewport, include_2d_entities)
}

fn serialize_session_view(
    session: &DocumentSession,
    viewport: Option<Bounds2>,
    include_2d_entities: bool,
) -> Result<String, String> {
    // Serialize borrowed geometry. Large polylines/meshes must not be cloned
    // just to produce a bridge packet; only candidate references are retained.
    #[derive(Serialize)]
    struct SceneView<'a> {
        layers: &'a [cad_core::Layer],
        entities: Vec<&'a cad_core::Entity2D>,
        bounds: Option<Bounds2>,
    }
    #[derive(Serialize)]
    struct Scene3DView<'a> {
        root_nodes: &'a [cad_core::AssemblyNode],
        meshes: &'a [cad_core::Mesh3D],
        materials: &'a [cad_core::Material3D],
        bounds: Option<cad_core::Bounds3>,
        stats: &'a cad_core::MeshStats,
    }
    #[derive(Serialize)]
    #[serde(tag = "scene_kind", content = "scene", rename_all = "snake_case")]
    enum SceneViewEnvelope<'a> {
        TwoD(SceneView<'a>),
        ThreeD(Scene3DView<'a>),
        Paged(&'a cad_core::PagedScene),
    }
    #[derive(Serialize)]
    struct DocumentView<'a> {
        metadata: &'a cad_core::DocumentMetadata,
        scene: SceneViewEnvelope<'a>,
        diagnostics: &'a [cad_core::FormatDiagnostic],
    }
    let scene = match &session.document.scene {
        SceneDocument::TwoD(source) => {
            let visible_layers = source
                .layers
                .iter()
                .filter(|layer| layer.visible)
                .map(|layer| layer.id)
                .collect::<HashSet<_>>();
            let entities = if !include_2d_entities {
                Vec::new()
            } else if let Some((bounds, index)) = viewport.zip(session.spatial_index.as_ref()) {
                index
                    .query_indices(bounds)
                    .into_iter()
                    .filter_map(|index| source.entities.get(index))
                    .filter(|entity| visible_layers.contains(&entity.layer_id))
                    .collect()
            } else {
                source
                    .entities
                    .iter()
                    .filter(|entity| visible_layers.contains(&entity.layer_id))
                    .collect()
            };
            SceneViewEnvelope::TwoD(SceneView {
                layers: &source.layers,
                entities,
                bounds: source.bounds,
            })
        }
        // Compact open and visibility responses retain mesh metadata only.
        SceneDocument::ThreeD(scene) => SceneViewEnvelope::ThreeD(Scene3DView {
            root_nodes: &scene.root_nodes,
            // Summary/visibility responses only change the assembly tree;
            // the UI retains the exact vertex/triangle buffers.
            meshes: if include_2d_entities {
                &scene.meshes
            } else {
                &[]
            },
            materials: &scene.materials,
            bounds: scene.bounds,
            stats: &scene.stats,
        }),
        SceneDocument::Paged(scene) => SceneViewEnvelope::Paged(scene),
    };
    serde_json::to_string(&DocumentView {
        metadata: &session.document.metadata,
        scene,
        diagnostics: &session.document.diagnostics,
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
    let discard = || {
        let _ = std::fs::remove_file(&cache_path);
        None
    };
    // Length-prefixed blobs after the magic.
    let mut blobs = Vec::new();
    let mut rest = match bytes.strip_prefix(CACHE_MAGIC) {
        Some(rest) => rest,
        None => return discard(),
    };
    while !rest.is_empty() {
        let Some((length, tail)) = rest.split_first_chunk::<8>() else {
            return discard();
        };
        let length = u64::from_le_bytes(*length) as usize;
        if length > tail.len() {
            return discard();
        }
        blobs.push(&tail[..length]);
        rest = &tail[length..];
    }
    let Some((header, chunks)) = blobs.split_first() else {
        return discard();
    };
    let header = match ciborium::from_reader::<SceneCacheHeader, _>(*header) {
        Ok(header) => header,
        Err(_) => return discard(),
    };
    if header.version != SCENE_CACHE_VERSION
        || header.parser_version != DWG_PARSER_VERSION
        || header.source_length != source_length
        || header.source_modified_nanos != source_modified_nanos
        || header.entity_chunks as usize != chunks.len()
    {
        return discard();
    }
    // Decode the entity chunks while the source is hashed.
    let (source_hash, decoded) = std::thread::scope(|scope| {
        let hash = scope.spawn(|| cad_core::fingerprint_path(path));
        let decoded = chunks
            .chunks(chunks.len().div_ceil(worker_threads()).max(1))
            .map(|group| {
                scope.spawn(move || {
                    group
                        .iter()
                        .map(|chunk| ciborium::from_reader::<Vec<cad_core::Entity2D>, _>(*chunk))
                        .collect::<Result<Vec<_>, _>>()
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|worker| worker.join().ok().and_then(Result::ok))
            .collect::<Option<Vec<_>>>();
        (hash.join(), decoded)
    });
    let source_hash = match source_hash {
        Ok(Ok(hash)) => hash,
        Ok(Err(error)) => return Some(Err(error.to_string())),
        Err(_) => return discard(),
    };
    if header.source_hash != source_hash {
        return discard();
    }
    let Some(decoded) = decoded else {
        return discard();
    };
    let scene = match header.scene {
        CachedScene::TwoD { layers, bounds } => {
            let mut entities = Vec::with_capacity(decoded.iter().flatten().map(Vec::len).sum());
            for chunk in decoded.into_iter().flatten() {
                entities.extend(chunk);
            }
            SceneDocument::TwoD(cad_core::Scene2D {
                layers,
                entities,
                bounds,
            })
        }
        CachedScene::Other(scene) => scene,
    };
    Some(Ok(OpenedDocument {
        metadata: header.metadata,
        scene,
        diagnostics: header.diagnostics,
    }))
}

fn write_cached_document(path: &Path, document: &OpenedDocument) {
    // Large DXF files incur the same normalization/index cost as DWG. Small
    // lightweight inputs and raster/mesh files do not need a redundant cache.
    if document.metadata.format != FormatId::Dwg
        && !(document.metadata.format == FormatId::Dxf
            && document.metadata.byte_length >= 4 * 1024 * 1024)
    {
        return;
    }
    let Some(cache_path) = scene_cache_path(path) else {
        return;
    };
    let Some((source_length, source_modified_nanos)) = source_state(path) else {
        return;
    };
    let (scene, entities): (CachedSceneRef<'_>, &[cad_core::Entity2D]) = match &document.scene {
        SceneDocument::TwoD(scene) => (
            CachedSceneRef::TwoD {
                layers: &scene.layers,
                bounds: scene.bounds,
            },
            &scene.entities,
        ),
        other => (CachedSceneRef::Other(other), &[]),
    };
    let threads = worker_threads();
    let chunk_size = entities.len().div_ceil(threads * 4).max(4096);
    let chunks = entities.chunks(chunk_size).collect::<Vec<_>>();
    let header = SceneCacheHeaderRef {
        version: SCENE_CACHE_VERSION,
        parser_version: DWG_PARSER_VERSION,
        source_length,
        source_modified_nanos,
        source_hash: &document.metadata.fingerprint,
        metadata: &document.metadata,
        diagnostics: &document.diagnostics,
        scene,
        entity_chunks: chunks.len() as u32,
    };
    // Unique temporary paths avoid collisions between the two open workers.
    let temporary_path = cache_path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let written = (|| -> std::io::Result<()> {
        use std::io::Write;
        let file = std::fs::File::create(&temporary_path)?;
        let mut writer = std::io::BufWriter::with_capacity(256 * 1024, file);
        writer.write_all(CACHE_MAGIC)?;
        let mut blob = |bytes: &[u8]| -> std::io::Result<()> {
            writer.write_all(&(bytes.len() as u64).to_le_bytes())?;
            writer.write_all(bytes)
        };
        let mut encoded = Vec::new();
        ciborium::into_writer(&header, &mut encoded).map_err(std::io::Error::other)?;
        blob(&encoded)?;
        // Encode a group of chunks in parallel, write it, then the next, so
        // at most one group of encoded chunks is held at a time.
        for group in chunks.chunks(threads) {
            let encoded = std::thread::scope(|scope| {
                group
                    .iter()
                    .map(|chunk| {
                        scope.spawn(move || {
                            let mut bytes = Vec::new();
                            ciborium::into_writer(chunk, &mut bytes).map(|()| bytes)
                        })
                    })
                    .collect::<Vec<_>>()
                    .into_iter()
                    .map(|worker| {
                        worker
                            .join()
                            .map_err(|_| std::io::Error::other("cache encoder panicked"))?
                            .map_err(std::io::Error::other)
                    })
                    .collect::<std::io::Result<Vec<_>>>()
            })?;
            for bytes in &encoded {
                blob(bytes)?;
            }
        }
        drop(blob);
        writer.flush()?;
        std::fs::rename(&temporary_path, &cache_path)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(temporary_path);
    }
}

pub fn document_summary(session_id: u64) -> Result<String, String> {
    serialize_session_document(session_id, Some(empty_bounds()), false)
}

#[derive(Serialize)]
struct TextLayoutItem<'a> {
    index: usize,
    id: u64,
    geometry: &'a Entity2DGeometry,
}

#[derive(Deserialize)]
struct MeasuredTextBounds {
    index: usize,
    id: u64,
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,
}

/// Bounded text-only pages, never a full drawing transfer. The cursor is a
/// scene-vector offset, not a text offset (no rescanning earlier geometry).
pub fn text_layout_batch(session_id: u64, start: u64) -> Result<String, String> {
    let sessions = SESSIONS.read();
    let session = sessions.get(&session_id).ok_or("unknown session")?;
    let SceneDocument::TwoD(scene) = &session.document.scene else {
        return Ok(r#"{"next":0,"total":0,"items":[]}"#.to_owned());
    };
    let start = usize::try_from(start).map_err(|_| "invalid text cursor")?;
    if start > scene.entities.len() {
        return Err("invalid text cursor".to_owned());
    }
    let mut next = start;
    let mut items = Vec::new();
    let mut payload_bytes = 256; // envelope/cursor and comma overhead
    while next < scene.entities.len() && items.len() < 64 {
        let entity = &scene.entities[next];
        if let Entity2DGeometry::Text(_) = &entity.geometry {
            let item = TextLayoutItem {
                index: next,
                id: entity.id,
                geometry: &entity.geometry,
            };
            let item_bytes = serde_json::to_vec(&item)
                .map_err(|error| error.to_string())?
                .len()
                + 1;
            // Include style runs, not only string bytes. A single oversized
            // label travels alone so the cursor always makes progress.
            if !items.is_empty() && payload_bytes + item_bytes > 64 * 1024 {
                break;
            }
            payload_bytes += item_bytes;
            items.push(item);
            if payload_bytes >= 64 * 1024 {
                next += 1;
                break;
            }
        }
        next += 1;
    }
    serde_json::to_string(&serde_json::json!({
        "next": next, "total": scene.entities.len(), "items": items,
    }))
    .map_err(|error| error.to_string())
}

/// Validate the entire packet before mutating a session. Envelopes are runtime
/// data: never trust a cache produced with different device/source fonts.
pub fn apply_text_layout_bounds(session_id: u64, packet: String) -> Result<(), String> {
    if packet.len() > 64 * 1024 {
        return Err("text bounds packet exceeds 64 KiB".to_owned());
    }
    let measured: Vec<MeasuredTextBounds> =
        serde_json::from_str(&packet).map_err(|error| error.to_string())?;
    if measured.len() > 64 {
        return Err("text bounds packet exceeds 64 entities".to_owned());
    }
    let mut sessions = SESSIONS.write();
    let session = sessions.get_mut(&session_id).ok_or("unknown session")?;
    let SceneDocument::TwoD(scene) = &session.document.scene else {
        return Err("document has no 2D text".to_owned());
    };
    for item in &measured {
        if ![item.min_x, item.min_y, item.max_x, item.max_y]
            .iter()
            .all(|v| v.is_finite())
            || item.min_x > item.max_x
            || item.min_y > item.max_y
        {
            return Err("invalid measured text bounds".to_owned());
        }
        if !scene.entities.get(item.index).is_some_and(|entity| {
            entity.id == item.id && matches!(entity.geometry, Entity2DGeometry::Text(_))
        }) {
            return Err("text bounds do not match the scene".to_owned());
        }
    }
    for item in measured {
        session.text_layout_bounds.insert(
            item.id,
            Bounds2 {
                min: Point2::new(item.min_x, item.min_y),
                max: Point2::new(item.max_x, item.max_y),
            },
        );
    }
    Ok(())
}

/// Commit only after every label was measured. Rebuild once, not per packet.
pub fn finalize_text_layout(session_id: u64) -> Result<String, String> {
    {
        let mut sessions = SESSIONS.write();
        let session = sessions.get_mut(&session_id).ok_or("unknown session")?;
        if let SceneDocument::TwoD(scene) = &mut session.document.scene {
            if scene.entities.iter().any(|entity| {
                matches!(entity.geometry, Entity2DGeometry::Text(_))
                    && !session.text_layout_bounds.contains_key(&entity.id)
            }) {
                return Err("text layout is incomplete".to_owned());
            }
            if !session.text_layout_bounds.is_empty() {
                let bounds_for = |entity: &cad_core::Entity2D| {
                    session
                        .text_layout_bounds
                        .get(&entity.id)
                        .copied()
                        .or_else(|| entity.bounds())
                };
                scene.bounds = scene.entities.iter().filter_map(bounds_for).fold(
                    None,
                    |acc: Option<Bounds2>, next| {
                        Some(match acc {
                            None => next,
                            Some(mut current) => {
                                current.include(next.min);
                                current.include(next.max);
                                current
                            }
                        })
                    },
                );
                session.spatial_index = Some(SceneIndex2D::build_with_bounds(scene, bounds_for));
            }
        }
    }
    document_summary(session_id)
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
        true,
    )
}

fn scene_packet_internal(session_id: u64, viewport: Option<Bounds2>) -> Result<Vec<u8>, String> {
    let sessions = SESSIONS.read();
    let session = sessions.get(&session_id).ok_or("unknown session")?;
    let SceneDocument::TwoD(scene) = &session.document.scene else {
        return Err("packed viewport requires a 2D scene".to_owned());
    };
    let visible = scene
        .layers
        .iter()
        .filter(|l| l.visible)
        .map(|l| l.id)
        .collect::<HashSet<_>>();
    let entities = if let Some((bounds, index)) = viewport.zip(session.spatial_index.as_ref()) {
        index
            .query_indices(bounds)
            .into_iter()
            .map(|i| &scene.entities[i])
            .filter(|e| visible.contains(&e.layer_id))
            .collect::<Vec<_>>()
    } else {
        scene
            .entities
            .iter()
            .filter(|e| visible.contains(&e.layer_id))
            .collect()
    };
    // Metadata and geometry are taken under the SAME read lock/generation.
    crate::scene_packet::encode_2d(&serialize_session_view(session, None, false)?, &entities)
}

pub fn document_packet(session_id: u64) -> Result<Vec<u8>, String> {
    let sessions = SESSIONS.read();
    let session = sessions.get(&session_id).ok_or("unknown session")?;
    if let SceneDocument::ThreeD(scene) = &session.document.scene {
        return crate::scene_packet::encode_3d(
            &serialize_session_view(session, None, false)?,
            &scene.meshes,
        );
    }
    // Do not recursively acquire a read lock: a queued writer could block it.
    drop(sessions);
    scene_packet_internal(session_id, None)
}

pub fn viewport_packet(
    session_id: u64,
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,
) -> Result<Vec<u8>, String> {
    if ![min_x, min_y, max_x, max_y].into_iter().all(f64::is_finite) {
        return Err("viewport bounds must be finite".to_owned());
    }
    scene_packet_internal(
        session_id,
        Some(Bounds2 {
            min: Point2::new(min_x.min(max_x), min_y.min(max_y)),
            max: Point2::new(min_x.max(max_x), min_y.max(max_y)),
        }),
    )
}

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
    set_visibilities(session_id, vec![VisibilityChange { item_id, visible }])
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_visibilities(session_id: u64, changes: Vec<VisibilityChange>) -> Result<String, String> {
    if changes
        .iter()
        .map(|change| change.item_id)
        .collect::<HashSet<_>>()
        .len()
        != changes.len()
    {
        return Err("visibility item ids must be unique".to_owned());
    }
    let mut sessions = SESSIONS.write();
    let session = sessions
        .get_mut(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?;
    match &mut session.document.scene {
        SceneDocument::TwoD(scene) => {
            let known = scene
                .layers
                .iter()
                .map(|layer| layer.id)
                .collect::<HashSet<_>>();
            if changes
                .iter()
                .any(|change| !known.contains(&change.item_id))
            {
                return Err("unknown layer".to_owned());
            }
            let change_map = changes
                .iter()
                .map(|change| (change.item_id, change.visible))
                .collect::<HashMap<_, _>>();
            for layer in &mut scene.layers {
                if let Some(visible) = change_map.get(&layer.id) {
                    layer.visible = *visible;
                }
            }
        }
        SceneDocument::ThreeD(scene) => {
            if changes
                .iter()
                .any(|change| !has_node(&scene.root_nodes, change.item_id))
            {
                return Err("unknown assembly node".to_owned());
            }
            for change in &changes {
                set_node_visibility(&mut scene.root_nodes, change.item_id, change.visible);
            }
        }
        SceneDocument::Paged(_) => return Err("paged documents have no visibility tree".to_owned()),
    }
    drop(sessions);
    if !changes.is_empty() {
        invalidate_session_viewports(session_id);
    }
    // The viewer follows a 2D visibility change with an exact viewport query;
    // avoid returning a second full-scene JSON payload in between.
    serialize_session_document(session_id, None, false)
}

/// Run candidate geometry checks on a bridge worker, never the UI thread.
pub fn hit_test(
    session_id: u64,
    x: f64,
    y: f64,
    tolerance: f64,
) -> Result<Option<HitResult>, String> {
    validate_pick(x, y, tolerance)?;
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
    Ok(candidates
        .into_iter()
        .filter_map(|index| scene.entities.get(index))
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

#[derive(Debug, Clone)]
pub struct RayHitResult {
    pub mesh_id: u64,
    pub triangle_index: u64,
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub distance: f64,
}

/// Worker-isolate ray pick against the retained, unsampled source triangles.
pub fn hit_test_ray(
    session_id: u64,
    ox: f64,
    oy: f64,
    oz: f64,
    dx: f64,
    dy: f64,
    dz: f64,
) -> Result<Option<RayHitResult>, String> {
    if ![ox, oy, oz, dx, dy, dz].into_iter().all(f64::is_finite) || dx.hypot(dy).hypot(dz) == 0.0 {
        return Err("invalid picking ray".to_owned());
    }
    let sessions = SESSIONS.read();
    let session = sessions.get(&session_id).ok_or("unknown session")?;
    let SceneDocument::ThreeD(scene) = &session.document.scene else {
        return Ok(None);
    };
    let Some(index) = &session.spatial_index_3d else {
        return Ok(None);
    };
    fn visible_meshes(nodes: &[cad_core::AssemblyNode], ids: &mut HashSet<u64>) {
        for node in nodes.iter().filter(|node| node.visible) {
            ids.extend(&node.mesh_ids);
            visible_meshes(&node.children, ids);
        }
    }
    let mut visible = HashSet::new();
    visible_meshes(&scene.root_nodes, &mut visible);
    let origin = Point3::new(ox, oy, oz);
    let direction = Point3::new(dx, dy, dz);
    let mut nearest: Option<RayHitResult> = None;
    for (mesh_index, triangle_index) in index.ray_candidates(origin, direction) {
        let mesh = &scene.meshes[mesh_index];
        if !visible.contains(&mesh.id) {
            continue;
        }
        let triangle = &mesh.indices[triangle_index * 3..triangle_index * 3 + 3];
        let Some(distance) = cad_core::ray_triangle_distance(
            origin,
            direction,
            mesh.positions[triangle[0] as usize],
            mesh.positions[triangle[1] as usize],
            mesh.positions[triangle[2] as usize],
        ) else {
            continue;
        };
        if nearest.as_ref().is_some_and(|hit| distance >= hit.distance) {
            continue;
        }
        nearest = Some(RayHitResult {
            mesh_id: mesh.id,
            triangle_index: triangle_index as u64,
            x: ox + dx * distance,
            y: oy + dy * distance,
            z: oz + dz * distance,
            distance,
        });
    }
    Ok(nearest)
}

#[flutter_rust_bridge::frb(sync)]
pub fn entity_count_summary(
    session_id: u64,
    entity_id: u64,
) -> Result<Option<EntityCountSummary>, String> {
    let sessions = SESSIONS.read();
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| "unknown session".to_owned())?;
    let SceneDocument::TwoD(scene) = &session.document.scene else {
        return Ok(None);
    };
    let Some(entity) = scene.entities.iter().find(|entity| entity.id == entity_id) else {
        return Ok(None);
    };
    let kind = entity_kind(&entity.geometry);
    Ok(Some(EntityCountSummary {
        entity_kind: kind.to_owned(),
        layer_id: entity.layer_id,
        same_kind_in_layer: session
            .layer_entity_kind_counts
            .get(&(entity.layer_id, kind.to_owned()))
            .copied()
            .unwrap_or(0),
        same_kind_in_document: session.entity_kind_counts.get(kind).copied().unwrap_or(0),
        same_kind_length_in_layer: session
            .layer_entity_kind_lengths
            .get(&(entity.layer_id, kind.to_owned()))
            .copied(),
        same_kind_length_in_document: session.entity_kind_lengths.get(kind).copied(),
        same_kind_area_in_layer: session
            .layer_entity_kind_areas
            .get(&(entity.layer_id, kind.to_owned()))
            .copied(),
        same_kind_area_in_document: session.entity_kind_areas.get(kind).copied(),
    }))
}

pub fn snap(session_id: u64, x: f64, y: f64, tolerance: f64) -> Result<Option<SnapResult>, String> {
    validate_pick(x, y, tolerance)?;
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
    let entities = candidates
        .into_iter()
        .filter_map(|index| scene.entities.get(index))
        .filter(|entity| {
            scene
                .layers
                .iter()
                .find(|layer| layer.id == entity.layer_id)
                .is_none_or(|layer| layer.visible)
        })
        .map(|entity| (entity.id, &entity.geometry))
        .collect::<Vec<_>>();
    let explicit = entities
        .iter()
        .filter_map(|(entity_id, geometry)| {
            nearest_snap_point(*entity_id, geometry, target, tolerance)
        })
        .min_by(|(_, _, _, a), (_, _, _, b)| a.total_cmp(b));
    // A crossing cannot beat an exact endpoint/vertex. Otherwise its search
    // radius only needs to reach the already-known nearest explicit point.
    let limit = explicit.as_ref().map_or(tolerance, |point| point.3);
    let intersection = if explicit.is_some() && limit == 0.0 {
        None
    } else {
        nearest_intersection(&entities, target, limit)
    };
    Ok(explicit
        .into_iter()
        .chain(intersection)
        .min_by(|(_, _, _, a), (_, _, _, b)| a.total_cmp(b))
        .map(|(entity_id, point, kind, distance)| SnapResult {
            entity_id,
            x: point.x,
            y: point.y,
            snap_kind: kind,
            distance,
        }))
}

/// Finds the nearest geometric intersection within the pick aperture.
///
/// This is separate from [`snap`] so tools that explicitly collect a boundary
/// can prefer a crossing without changing the nearest-snap behaviour used by
/// distance, coordinate and editing tools.
pub fn snap_intersection(
    session_id: u64,
    x: f64,
    y: f64,
    tolerance: f64,
) -> Result<Option<SnapResult>, String> {
    validate_pick(x, y, tolerance)?;
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
    let entities = candidates
        .into_iter()
        .filter_map(|index| scene.entities.get(index))
        .filter(|entity| {
            scene
                .layers
                .iter()
                .find(|layer| layer.id == entity.layer_id)
                .is_none_or(|layer| layer.visible)
        })
        .map(|entity| (entity.id, &entity.geometry))
        .collect::<Vec<_>>();
    Ok(nearest_intersection(&entities, target, tolerance).map(
        |(entity_id, point, kind, distance)| SnapResult {
            entity_id,
            x: point.x,
            y: point.y,
            snap_kind: kind,
            distance,
        },
    ))
}

fn validate_pick(x: f64, y: f64, tolerance: f64) -> Result<(), String> {
    if [
        x,
        y,
        tolerance,
        x - tolerance,
        x + tolerance,
        y - tolerance,
        y + tolerance,
    ]
    .into_iter()
    .all(f64::is_finite)
    {
        Ok(())
    } else {
        Err("invalid pick coordinates or tolerance".to_owned())
    }
}

fn spatial_candidates(session: &DocumentSession, target: Point2, tolerance: f64) -> Vec<usize> {
    session
        .spatial_index
        .as_ref()
        .map(|index| {
            index.query_indices(Bounds2 {
                min: Point2::new(target.x - tolerance, target.y - tolerance),
                max: Point2::new(target.x + tolerance, target.y + tolerance),
            })
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

fn has_node(nodes: &[cad_core::AssemblyNode], id: u64) -> bool {
    nodes
        .iter()
        .any(|node| node.id == id || has_node(&node.children, id))
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
        Entity2DGeometry::Circle { center, radius } => {
            Some((distance_2d(*center, target) - radius.abs()).abs())
        }
        Entity2DGeometry::Arc {
            center,
            radius,
            start_angle,
            end_angle,
        } => {
            let radius = radius.abs();
            if angle_on_arc(target, *center, *start_angle, *end_angle) {
                Some((distance_2d(*center, target) - radius).abs())
            } else {
                let start = point_on_circle(*center, radius, *start_angle);
                let end = point_on_circle(*center, radius, *end_angle);
                Some(distance_2d(target, start).min(distance_2d(target, end)))
            }
        }
        Entity2DGeometry::Text(text_geometry) => {
            let TextGeometry2D { origin, .. } = &**text_geometry;
            Some(distance_2d(*origin, target))
        }
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

fn nearest_snap_point(
    entity_id: u64,
    geometry: &Entity2DGeometry,
    target: Point2,
    tolerance: f64,
) -> Option<(u64, Point2, String, f64)> {
    // Scan borrowed vertices instead of allocating a point+String for every
    // vertex of a large polyline on every pointer move.
    let mut best: Option<(Point2, &'static str, f64)> = None;
    let mut consider = |point: Point2, kind: &'static str| {
        let distance = distance_2d(target, point);
        if distance <= tolerance && best.as_ref().is_none_or(|b| distance < b.2) {
            best = Some((point, kind, distance));
        }
    };
    match geometry {
        Entity2DGeometry::Point { position } => consider(*position, "point"),
        Entity2DGeometry::Line { start, end } => {
            consider(*start, "endpoint");
            consider(*end, "endpoint");
            consider(
                Point2::new(start.x * 0.5 + end.x * 0.5, start.y * 0.5 + end.y * 0.5),
                "midpoint",
            );
        }
        Entity2DGeometry::Polyline { points, .. } => {
            for point in points {
                consider(*point, "vertex");
            }
        }
        Entity2DGeometry::Circle { center, .. } => consider(*center, "center"),
        Entity2DGeometry::Arc {
            center,
            radius,
            start_angle,
            end_angle,
        } => {
            consider(*center, "center");
            consider(point_on_circle(*center, *radius, *start_angle), "endpoint");
            consider(point_on_circle(*center, *radius, *end_angle), "endpoint");
        }
        Entity2DGeometry::Text(text) => consider(text.origin, "insertion"),
    }
    best.map(|(point, kind, distance)| (entity_id, point, kind.to_owned(), distance))
}

#[derive(Clone, Copy)]
enum SnapCurve {
    Segment {
        entity_id: u64,
        start: Point2,
        end: Point2,
    },
    Circular {
        entity_id: u64,
        center: Point2,
        radius: f64,
        arc: Option<(f64, f64)>,
    },
}

impl SnapCurve {
    fn key(self) -> [u64; 7] {
        fn bits(value: f64) -> u64 {
            if value == 0.0 {
                0
            } else {
                value.to_bits()
            }
        }
        match self {
            Self::Segment { start, end, .. } => {
                let a = [bits(start.x), bits(start.y)];
                let b = [bits(end.x), bits(end.y)];
                let (a, b) = if a <= b { (a, b) } else { (b, a) };
                [0, a[0], a[1], b[0], b[1], 0, 0]
            }
            Self::Circular {
                center,
                radius,
                arc,
                ..
            } => {
                let (kind, start, end) = arc.map_or((1, 0.0, 0.0), |(s, e)| (2, s, e));
                [
                    kind,
                    bits(center.x),
                    bits(center.y),
                    bits(radius),
                    bits(start),
                    bits(end),
                    0,
                ]
            }
        }
    }

    fn bounds(self) -> Bounds2 {
        match self {
            Self::Segment { start, end, .. } => Bounds2 {
                min: Point2::new(start.x.min(end.x), start.y.min(end.y)),
                max: Point2::new(start.x.max(end.x), start.y.max(end.y)),
            },
            Self::Circular { center, radius, .. } => Bounds2 {
                min: Point2::new(center.x - radius, center.y - radius),
                max: Point2::new(center.x + radius, center.y + radius),
            },
        }
    }

    fn entity_id(self) -> u64 {
        match self {
            Self::Segment { entity_id, .. } | Self::Circular { entity_id, .. } => entity_id,
        }
    }

    fn contains(self, point: Point2) -> bool {
        match self {
            Self::Segment { .. } | Self::Circular { arc: None, .. } => true,
            Self::Circular {
                center,
                arc: Some((start, end)),
                ..
            } => angle_on_arc(point, center, start, end),
        }
    }

    fn distance_to(self, target: Point2) -> f64 {
        match self {
            Self::Segment { start, end, .. } => point_segment_distance(target, start, end),
            Self::Circular { center, radius, .. } => (distance_2d(target, center) - radius).abs(),
        }
    }
}

fn nearest_intersection(
    entities: &[(u64, &Entity2DGeometry)],
    target: Point2,
    tolerance: f64,
) -> Option<(u64, Point2, String, f64)> {
    // A fixed nearest-curve cap loses real crossings: hundreds of nearby
    // parallel hatch lines can exclude the one transverse boundary. Retain
    // every nearby curve, deduplicate exact coincident geometry and use local
    // envelopes plus distance lower bounds to avoid irrelevant pair checks.
    let mut curves = Vec::new();
    for (entity_id, geometry) in entities {
        append_nearby_curves(&mut curves, *entity_id, geometry, target, tolerance);
    }
    let mut seen = HashSet::new();
    curves.retain(|curve| seen.insert(curve.key()));
    drop(seen);
    let mut curves = curves
        .into_iter()
        .map(|curve| (curve, curve.distance_to(target)))
        .collect::<Vec<_>>();
    curves.sort_by(|a, b| a.1.total_cmp(&b.1));
    if curves.len() < 2 {
        return None;
    }
    let index = SceneIndex2D::from_bounds(curves.iter().map(|(curve, _)| curve.bounds()));

    let mut best: Option<(u64, Point2, String, f64)> = None;
    for first_index in 0..curves.len() {
        let limit = best.as_ref().map_or(tolerance, |best| best.3);
        // Expand lower-bound comparisons for floating-point roundoff. Exact
        // candidate points still have to satisfy the original pick aperture.
        let margin =
            32.0 * f64::EPSILON * target.x.abs().max(target.y.abs()).max(tolerance).max(1.0);
        if curves[first_index].1 > limit + margin {
            break;
        }
        let first = curves[first_index].0;
        let bounds = first.bounds();
        let query = Bounds2 {
            min: Point2::new(
                bounds.min.x.max(target.x - limit - margin),
                bounds.min.y.max(target.y - limit - margin),
            ),
            max: Point2::new(
                bounds.max.x.min(target.x + limit + margin),
                bounds.max.y.min(target.y + limit + margin),
            ),
        };
        if query.min.x > query.max.x || query.min.y > query.max.y {
            continue;
        }
        for second_index in index.query_indices(query) {
            if second_index <= first_index {
                continue;
            }
            if curves[second_index].1 > limit + margin {
                break;
            }
            let second = curves[second_index].0;
            for point in curve_intersections(first, second) {
                if !first.contains(point) || !second.contains(point) {
                    continue;
                }
                let distance = distance_2d(target, point);
                if distance > tolerance {
                    continue;
                }
                if best
                    .as_ref()
                    .is_none_or(|(_, _, _, current)| distance < *current)
                {
                    best = Some((
                        first.entity_id(),
                        point,
                        "intersection".to_owned(),
                        distance,
                    ));
                }
            }
        }
    }
    best
}

fn append_nearby_curves(
    curves: &mut Vec<SnapCurve>,
    entity_id: u64,
    geometry: &Entity2DGeometry,
    target: Point2,
    tolerance: f64,
) {
    let mut push_segment = |start: Point2, end: Point2| {
        if point_segment_distance(target, start, end) <= tolerance {
            curves.push(SnapCurve::Segment {
                entity_id,
                start,
                end,
            });
        }
    };
    match geometry {
        Entity2DGeometry::Line { start, end } => push_segment(*start, *end),
        Entity2DGeometry::Polyline { points, closed } => {
            for segment in points.windows(2) {
                push_segment(segment[0], segment[1]);
            }
            if *closed && points.len() > 2 {
                push_segment(*points.last().unwrap(), points[0]);
            }
        }
        Entity2DGeometry::Circle { center, radius } => {
            if (distance_2d(target, *center) - radius.abs()).abs() <= tolerance {
                curves.push(SnapCurve::Circular {
                    entity_id,
                    center: *center,
                    radius: radius.abs(),
                    arc: None,
                });
            }
        }
        Entity2DGeometry::Arc {
            center,
            radius,
            start_angle,
            end_angle,
        } => {
            if (distance_2d(target, *center) - radius.abs()).abs() <= tolerance {
                curves.push(SnapCurve::Circular {
                    entity_id,
                    center: *center,
                    radius: radius.abs(),
                    arc: Some((*start_angle, *end_angle)),
                });
            }
        }
        Entity2DGeometry::Point { .. } | Entity2DGeometry::Text(_) => {}
    }
}

fn curve_intersections(first: SnapCurve, second: SnapCurve) -> Vec<Point2> {
    match (first, second) {
        (
            SnapCurve::Segment {
                start: first_start,
                end: first_end,
                ..
            },
            SnapCurve::Segment {
                start: second_start,
                end: second_end,
                ..
            },
        ) => segment_intersection(first_start, first_end, second_start, second_end)
            .into_iter()
            .collect(),
        (SnapCurve::Segment { start, end, .. }, SnapCurve::Circular { center, radius, .. })
        | (SnapCurve::Circular { center, radius, .. }, SnapCurve::Segment { start, end, .. }) => {
            segment_circle_intersections(start, end, center, radius)
        }
        (
            SnapCurve::Circular {
                center: first_center,
                radius: first_radius,
                ..
            },
            SnapCurve::Circular {
                center: second_center,
                radius: second_radius,
                ..
            },
        ) => circle_intersections(first_center, first_radius, second_center, second_radius),
    }
}

fn segment_intersection(a: Point2, b: Point2, c: Point2, d: Point2) -> Option<Point2> {
    let r = Point2::new(b.x - a.x, b.y - a.y);
    let s = Point2::new(d.x - c.x, d.y - c.y);
    let denominator = cross(r, s);
    let epsilon = 1e-12 * (r.x.hypot(r.y) * s.x.hypot(s.y)).max(1.0);
    if denominator.abs() <= epsilon {
        return None;
    }
    let offset = Point2::new(c.x - a.x, c.y - a.y);
    let t = cross(offset, s) / denominator;
    let u = cross(offset, r) / denominator;
    if !(-1e-10..=1.0 + 1e-10).contains(&t) || !(-1e-10..=1.0 + 1e-10).contains(&u) {
        return None;
    }
    Some(Point2::new(a.x + t * r.x, a.y + t * r.y))
}

fn segment_circle_intersections(
    start: Point2,
    end: Point2,
    center: Point2,
    radius: f64,
) -> Vec<Point2> {
    let dx = end.x - start.x;
    let dy = end.y - start.y;
    let fx = start.x - center.x;
    let fy = start.y - center.y;
    let a = dx * dx + dy * dy;
    if a <= f64::EPSILON || radius <= 0.0 {
        return Vec::new();
    }
    let b = 2.0 * (fx * dx + fy * dy);
    let c = fx * fx + fy * fy - radius * radius;
    let discriminant = b * b - 4.0 * a * c;
    if discriminant < -1e-10 {
        return Vec::new();
    }
    let root = discriminant.max(0.0).sqrt();
    let mut points = Vec::with_capacity(2);
    for t in [(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)] {
        if (-1e-10..=1.0 + 1e-10).contains(&t) {
            let point = Point2::new(start.x + t * dx, start.y + t * dy);
            if points
                .iter()
                .all(|existing| distance_2d(*existing, point) > 1e-9)
            {
                points.push(point);
            }
        }
    }
    points
}

fn circle_intersections(
    first: Point2,
    first_radius: f64,
    second: Point2,
    second_radius: f64,
) -> Vec<Point2> {
    let distance = distance_2d(first, second);
    if distance <= 1e-12
        || distance > first_radius + second_radius + 1e-10
        || distance < (first_radius - second_radius).abs() - 1e-10
    {
        return Vec::new();
    }
    let along = (first_radius * first_radius - second_radius * second_radius + distance * distance)
        / (2.0 * distance);
    let height = (first_radius * first_radius - along * along)
        .max(0.0)
        .sqrt();
    let base_x = first.x + along * (second.x - first.x) / distance;
    let base_y = first.y + along * (second.y - first.y) / distance;
    let offset_x = -height * (second.y - first.y) / distance;
    let offset_y = height * (second.x - first.x) / distance;
    let first_point = Point2::new(base_x + offset_x, base_y + offset_y);
    let second_point = Point2::new(base_x - offset_x, base_y - offset_y);
    if distance_2d(first_point, second_point) <= 1e-9 {
        vec![first_point]
    } else {
        vec![first_point, second_point]
    }
}

fn point_on_circle(center: Point2, radius: f64, angle: f64) -> Point2 {
    Point2::new(
        center.x + radius * angle.cos(),
        center.y + radius * angle.sin(),
    )
}

fn angle_on_arc(point: Point2, center: Point2, start: f64, end: f64) -> bool {
    let angle = (point.y - center.y).atan2(point.x - center.x);
    (angle - start).rem_euclid(std::f64::consts::TAU) <= normalized_arc_sweep(start, end) + 1e-10
}

fn normalized_arc_sweep(start: f64, end: f64) -> f64 {
    let sweep = (end - start).rem_euclid(std::f64::consts::TAU);
    if sweep <= 1e-12 {
        std::f64::consts::TAU
    } else {
        sweep
    }
}

fn cross(first: Point2, second: Point2) -> f64 {
    first.x * second.y - first.y * second.x
}

fn entity_kind(geometry: &Entity2DGeometry) -> &'static str {
    match geometry {
        Entity2DGeometry::Point { .. } => "point",
        Entity2DGeometry::Line { .. } => "line",
        Entity2DGeometry::Polyline { .. } => "polyline",
        Entity2DGeometry::Circle { .. } => "circle",
        Entity2DGeometry::Arc { .. } => "arc",
        Entity2DGeometry::Text(_) => "text",
    }
}

fn entity_length(geometry: &Entity2DGeometry) -> Option<f64> {
    let length = match geometry {
        Entity2DGeometry::Line { start, end } => distance_2d(*start, *end),
        Entity2DGeometry::Polyline { points, closed } if points.len() >= 2 => {
            let mut length = points
                .windows(2)
                .map(|segment| distance_2d(segment[0], segment[1]))
                .sum::<f64>();
            if *closed && points.len() > 2 {
                length += distance_2d(*points.last()?, points[0]);
            }
            length
        }
        Entity2DGeometry::Circle { radius, .. } if radius.is_finite() && *radius != 0.0 => {
            std::f64::consts::TAU * radius.abs()
        }
        Entity2DGeometry::Arc {
            radius,
            start_angle,
            end_angle,
            ..
        } if radius.is_finite()
            && *radius != 0.0
            && start_angle.is_finite()
            && end_angle.is_finite() =>
        {
            radius.abs() * normalized_arc_sweep(*start_angle, *end_angle)
        }
        Entity2DGeometry::Point { .. }
        | Entity2DGeometry::Text(_)
        | Entity2DGeometry::Polyline { .. }
        | Entity2DGeometry::Circle { .. }
        | Entity2DGeometry::Arc { .. } => return None,
    };
    (length.is_finite() && length >= 0.0).then_some(length)
}

fn entity_area(geometry: &Entity2DGeometry) -> Option<f64> {
    match geometry {
        Entity2DGeometry::Circle { radius, .. } if radius.is_finite() && *radius != 0.0 => {
            let area = std::f64::consts::PI * radius * radius;
            area.is_finite().then_some(area)
        }
        Entity2DGeometry::Polyline {
            points,
            closed: true,
        } => simple_polygon_area(points, 4096),
        Entity2DGeometry::Point { .. }
        | Entity2DGeometry::Line { .. }
        | Entity2DGeometry::Polyline { .. }
        | Entity2DGeometry::Circle { .. }
        | Entity2DGeometry::Arc { .. }
        | Entity2DGeometry::Text(_) => None,
    }
}

fn build_entity_statistics(
    document: &OpenedDocument,
) -> (
    HashMap<String, u64>,
    HashMap<(u64, String), u64>,
    HashMap<String, f64>,
    HashMap<(u64, String), f64>,
    HashMap<String, f64>,
    HashMap<(u64, String), f64>,
) {
    let mut by_kind = HashMap::new();
    let mut by_layer_and_kind = HashMap::new();
    let mut lengths_by_kind = HashMap::new();
    let mut lengths_by_layer_and_kind = HashMap::new();
    let mut areas_by_kind = HashMap::new();
    let mut areas_by_layer_and_kind = HashMap::new();
    let SceneDocument::TwoD(scene) = &document.scene else {
        return (
            by_kind,
            by_layer_and_kind,
            lengths_by_kind,
            lengths_by_layer_and_kind,
            areas_by_kind,
            areas_by_layer_and_kind,
        );
    };
    for entity in &scene.entities {
        let kind = entity_kind(&entity.geometry).to_owned();
        *by_kind.entry(kind.clone()).or_default() += 1;
        *by_layer_and_kind
            .entry((entity.layer_id, kind.clone()))
            .or_default() += 1;
        if let Some(length) = entity_length(&entity.geometry) {
            *lengths_by_kind.entry(kind.clone()).or_default() += length;
            *lengths_by_layer_and_kind
                .entry((entity.layer_id, kind.clone()))
                .or_default() += length;
        }
        if let Some(area) = entity_area(&entity.geometry) {
            *areas_by_kind.entry(kind.clone()).or_default() += area;
            *areas_by_layer_and_kind
                .entry((entity.layer_id, kind))
                .or_default() += area;
        }
    }
    (
        by_kind,
        by_layer_and_kind,
        lengths_by_kind,
        lengths_by_layer_and_kind,
        areas_by_kind,
        areas_by_layer_and_kind,
    )
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

    /// Release-mode, opt-in benchmark of the real open/viewport/pick APIs.
    /// Run in isolation: CADVIEW_PERF_FILE=/absolute/file cargo test --release
    /// performance_file -- --ignored --nocapture --test-threads=1
    #[test]
    #[ignore = "requires an explicitly selected local performance corpus"]
    fn performance_file() {
        use std::time::Instant;
        let path = std::env::var("CADVIEW_PERF_FILE").expect("CADVIEW_PERF_FILE");
        let cache = std::env::var("CADVIEW_PERF_CACHE").ok();
        if let Some(cache) = cache {
            configure_cache(cache).unwrap();
        }
        let start = Instant::now();
        let opened = open_document(path.clone()).unwrap();
        let cold_ms = start.elapsed().as_secs_f64() * 1000.0;
        let initial_json_bytes = opened.document_json.len();
        if let Ok(output) = std::env::var("CADVIEW_PERF_DOCUMENT_JSON") {
            std::fs::write(output, &opened.document_json).unwrap();
        }
        let (bounds, triangles, pick_targets) = {
            let sessions = SESSIONS.read();
            match &sessions[&opened.session_id].document.scene {
                SceneDocument::TwoD(scene) => {
                    let hidden = scene
                        .layers
                        .iter()
                        .filter(|layer| !layer.visible)
                        .map(|layer| layer.id)
                        .collect::<HashSet<_>>();
                    // Sample actual visible geometry. A fixed grid can land
                    // entirely in empty areas of tiled engineering drawings,
                    // giving misleading near-zero hit/snap timings.
                    let targets = scene
                        .entities
                        .iter()
                        .filter(|entity| !hidden.contains(&entity.layer_id))
                        .filter_map(|entity| match &entity.geometry {
                            Entity2DGeometry::Line { start, .. } => Some(*start),
                            Entity2DGeometry::Point { position } => Some(*position),
                            Entity2DGeometry::Polyline { points, .. } => points.first().copied(),
                            _ => None,
                        })
                        .step_by((scene.entities.len() / 100).max(1))
                        .take(100)
                        .collect::<Vec<_>>();
                    (scene.bounds, 0, targets)
                }
                SceneDocument::ThreeD(scene) => (None, scene.stats.triangle_count, Vec::new()),
                _ => (None, 0, Vec::new()),
            }
        };
        let mut full_packet_bytes = 0;
        let mut full_packet_ms = 0.0;
        if (bounds.is_some() || triangles > 0) && std::env::var_os("CADVIEW_PERF_PACKET").is_some()
        {
            let start = Instant::now();
            let packet = document_packet(opened.session_id).unwrap();
            full_packet_ms = start.elapsed().as_secs_f64() * 1000.0;
            full_packet_bytes = packet.len();
            std::fs::write(std::env::var("CADVIEW_PERF_PACKET").unwrap(), packet).unwrap();
        }
        let mut viewport = Vec::new();
        let mut hit = Vec::new();
        let mut snaps = Vec::new();
        let mut hit_count = 0;
        let mut snap_count = 0;
        let mut viewport_bytes = 0;
        if let Some(bounds) = bounds {
            let width = bounds.max.x - bounds.min.x;
            let height = bounds.max.y - bounds.min.y;
            assert!(
                !pick_targets.is_empty(),
                "benchmark requires visible point/line/polyline geometry"
            );
            for target in &pick_targets {
                let (x, y) = (target.x, target.y);
                let start = Instant::now();
                let json =
                    viewport_document(opened.session_id, x, y, x + width * 0.01, y + height * 0.01)
                        .unwrap();
                viewport.push(start.elapsed().as_secs_f64() * 1000.0);
                viewport_bytes = json.len();
                let start = Instant::now();
                hit_count += u64::from(hit_test(opened.session_id, x, y, 0.01).unwrap().is_some());
                hit.push(start.elapsed().as_secs_f64() * 1000.0);
                let start = Instant::now();
                snap_count += u64::from(snap(opened.session_id, x, y, 0.01).unwrap().is_some());
                snaps.push(start.elapsed().as_secs_f64() * 1000.0);
            }
            assert_eq!(hit_count, pick_targets.len() as u64);
            assert_eq!(snap_count, pick_targets.len() as u64);
        }
        let mut ray_times = Vec::new();
        let mut ray_hits = 0;
        if triangles > 0 {
            let bounds = {
                let sessions = SESSIONS.read();
                let SceneDocument::ThreeD(scene) = &sessions[&opened.session_id].document.scene
                else {
                    unreachable!()
                };
                scene.bounds.unwrap()
            };
            for step in 0..100 {
                let x = bounds.min.x
                    + (bounds.max.x - bounds.min.x) * (0.1 + (step % 80) as f64 / 100.0);
                let y = (bounds.min.y + bounds.max.y) * 0.5;
                let z = bounds.max.z + (bounds.max.z - bounds.min.z).max(1.0);
                let start = Instant::now();
                if hit_test_ray(opened.session_id, x, y, z, 0.0, 0.0, -1.0)
                    .unwrap()
                    .is_some()
                {
                    ray_hits += 1;
                }
                ray_times.push(start.elapsed().as_secs_f64() * 1000.0);
            }
        }
        fn p95(values: &mut [f64]) -> Option<f64> {
            values.sort_by(f64::total_cmp);
            values
                .get(values.len().saturating_sub(values.len() / 20 + 1))
                .copied()
        }
        let entity_count = opened.total_entity_count;
        close_document(opened.session_id);
        drop(opened);
        let start = Instant::now();
        let reopened = open_document(path.clone()).unwrap();
        let warm_ms = start.elapsed().as_secs_f64() * 1000.0;
        close_document(reopened.session_id);
        println!(
            "PERFORMANCE {}",
            serde_json::json!({
            "path":path, "bytes":std::fs::metadata(&path).unwrap().len(),
            "entity_stride_bytes":std::mem::size_of::<cad_core::Entity2D>(),
                "entities":entity_count, "triangles":triangles,
                "first_open_ms":cold_ms, "reopen_ms":warm_ms,
                "initial_json_bytes":initial_json_bytes, "viewport_json_bytes":viewport_bytes,
                "full_packet_bytes":full_packet_bytes, "full_packet_ms":full_packet_ms,
                "viewport_p95_ms":p95(&mut viewport), "hit_p95_ms":p95(&mut hit), "snap_p95_ms":p95(&mut snaps),
            "ray_p95_ms":p95(&mut ray_times), "ray_hits":ray_hits,
                "hit_count":hit_count, "snap_count":snap_count,
                "query_count":pick_targets.len(),
            })
        );
    }

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
    fn packed_scene_matches_legacy_geometry_metadata_order_and_visibility() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("packed.dxf");
        std::fs::write(&path, "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1032\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nPOINT\n8\n0\n10\n5\n20\n6\n0\nLINE\n8\n0\n10\n1000000000000.125\n20\n15\n11\n1000000000004.125\n21\n15\n0\nLWPOLYLINE\n8\n0\n90\n3\n70\n1\n10\n0\n20\n0\n10\n10\n20\n0\n10\n5\n20\n8\n0\nCIRCLE\n8\n0\n10\n5\n20\n5\n40\n2.5\n0\nARC\n8\n0\n10\n5\n20\n5\n40\n3\n50\n10\n51\n210\n0\nTEXT\n8\n0\n10\n5\n20\n5\n40\n2\n1\n中文⌀42\n0\nENDSEC\n0\nEOF\n").unwrap();
        let opened = open_document(path.to_string_lossy().into_owned()).unwrap();
        let id = opened.session_id;
        {
            let mut sessions = SESSIONS.write();
            let SceneDocument::TwoD(scene) = &mut sessions.get_mut(&id).unwrap().document.scene
            else {
                panic!()
            };
            scene.entities[1].dash = vec![4.0, -2.0, 0.0];
            scene.entities[2].filled = true;
            scene.entities[2].stroke_width = 1.25;
        }
        let legacy: serde_json::Value =
            serde_json::from_str(&serialize_session_document(id, None, true).unwrap()).unwrap();
        let packed = crate::scene_packet::tests::decode(&document_packet(id).unwrap());
        assert_eq!(packed, legacy);
        assert_eq!(
            packed["scene"]["scene"]["entities"]
                .as_array()
                .unwrap()
                .len(),
            6
        );
        for bounds in [[-10.0, -10.0, 20.0, 20.0], [1e12, 0.0, 1e12 + 10.0, 30.0]] {
            let expected: serde_json::Value = serde_json::from_str(
                &viewport_document(id, bounds[0], bounds[1], bounds[2], bounds[3]).unwrap(),
            )
            .unwrap();
            assert_eq!(
                crate::scene_packet::tests::decode(
                    &viewport_packet(id, bounds[0], bounds[1], bounds[2], bounds[3]).unwrap()
                ),
                expected
            );
        }
        let layer = packed["scene"]["scene"]["layers"][0]["id"]
            .as_u64()
            .unwrap();
        set_visibility(id, layer, false).unwrap();
        let hidden = crate::scene_packet::tests::decode(&document_packet(id).unwrap());
        assert!(hidden["scene"]["scene"]["entities"]
            .as_array()
            .unwrap()
            .is_empty());
        assert!(viewport_packet(id, f64::NAN, 0.0, 1.0, 1.0).is_err());
        close_document(id);
        assert!(document_packet(id).is_err());
    }

    #[test]
    fn compact_mesh_open_keeps_exact_legacy_scene_without_initial_geometry_json() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("compact.obj");
        std::fs::write(&path, "o exact\nv 1000000000000.125 0 0\nv 1000000000001.125 0 0\nv 1000000000000.125 1 0\nf 3 1 2\n").unwrap();
        let opened = open_document_internal(
            path.to_string_lossy().into_owned(),
            &CancellationToken::default(),
            None,
            true,
        )
        .unwrap();
        let id = opened.session_id;
        assert_eq!(opened.scene_kind, "three_d");
        let summary: serde_json::Value = serde_json::from_str(&opened.document_json).unwrap();
        assert!(summary["scene"]["scene"]["meshes"]
            .as_array()
            .unwrap()
            .is_empty());
        let legacy: serde_json::Value =
            serde_json::from_str(&serialize_session_document(id, None, true).unwrap()).unwrap();
        assert_eq!(
            crate::scene_packet::tests::decode_3d(&document_packet(id).unwrap()),
            legacy
        );
        let node = summary["scene"]["scene"]["root_nodes"][0]["id"]
            .as_u64()
            .unwrap();
        set_visibility(id, node, false).unwrap();
        let hidden = crate::scene_packet::tests::decode_3d(&document_packet(id).unwrap());
        assert_eq!(
            hidden["scene"]["scene"]["meshes"],
            legacy["scene"]["scene"]["meshes"]
        );
        assert_eq!(hidden["scene"]["scene"]["root_nodes"][0]["visible"], false);
        assert!(viewport_packet(id, 0.0, 0.0, 1.0, 1.0).is_err());
        close_document(id);
        assert!(document_packet(id).is_err());
    }

    #[test]
    fn indexed_ray_pick_matches_exact_brute_force_and_assembly_visibility() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("ray.obj");
        std::fs::write(&path, "o back\nv 0 0 0\nv 10 0 0\nv 0 10 0\nf 1 2 3\no front\nv 0 0 2\nv 10 0 2\nv 0 10 2\nf 4 5 6\n").unwrap();
        let opened = open_document(path.to_string_lossy().into_owned()).unwrap();
        let id = opened.session_id;
        for x in [-1.0, 0.0, 1.0, 5.0, 10.0, 11.0] {
            for y in [-1.0, 0.0, 1.0, 5.0, 10.0, 11.0] {
                let expected = {
                    let sessions = SESSIONS.read();
                    let SceneDocument::ThreeD(scene) = &sessions[&id].document.scene else {
                        panic!()
                    };
                    scene
                        .meshes
                        .iter()
                        .flat_map(|mesh| {
                            mesh.indices
                                .chunks_exact(3)
                                .enumerate()
                                .filter_map(move |(i, t)| {
                                    cad_core::ray_triangle_distance(
                                        Point3::new(x, y, 5.0),
                                        Point3::new(0.0, 0.0, -1.0),
                                        mesh.positions[t[0] as usize],
                                        mesh.positions[t[1] as usize],
                                        mesh.positions[t[2] as usize],
                                    )
                                    .map(|d| (mesh.id, i as u64, d))
                                })
                        })
                        .min_by(|a, b| a.2.total_cmp(&b.2))
                };
                let actual = hit_test_ray(id, x, y, 5.0, 0.0, 0.0, -1.0).unwrap();
                assert_eq!(
                    actual.map(|hit| (hit.mesh_id, hit.triangle_index, hit.distance)),
                    expected
                );
            }
        }
        let hit = hit_test_ray(id, 1.0, 1.0, 5.0, 0.0, 0.0, -1.0)
            .unwrap()
            .unwrap();
        assert_eq!(hit.z, 2.0);
        assert_eq!(
            hit_test_ray(id, 0.0, 0.0, 5.0, 0.2, 0.2, -1.0)
                .unwrap()
                .unwrap()
                .z,
            2.0
        );
        let summary: OpenedDocument = serde_json::from_str(&document_summary(id).unwrap()).unwrap();
        let SceneDocument::ThreeD(summary) = summary.scene else {
            panic!()
        };
        assert!(summary.meshes.is_empty());
        assert_eq!(summary.stats.triangle_count, 2);
        set_visibility(id, hit.mesh_id, false).unwrap();
        assert_eq!(
            hit_test_ray(id, 1.0, 1.0, 5.0, 0.0, 0.0, -1.0)
                .unwrap()
                .unwrap()
                .z,
            0.0
        );
        set_visibility(id, 0, false).unwrap();
        assert!(hit_test_ray(id, 1.0, 1.0, 5.0, 0.0, 0.0, -1.0)
            .unwrap()
            .is_none());
        assert!(hit_test_ray(id, 1.0, 1.0, 5.0, 0.0, 0.0, 0.0).is_err());
        close_document(id);
    }

    #[test]
    fn text_metadata_pages_account_for_style_payload_and_preserve_all_runs() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("rich-pages.dxf");
        let mut source = String::from(
            "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1021\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n",
        );
        for index in 0..4 {
            source.push_str(&format!(
                "0\nMTEXT\n10\n0\n20\n{}\n40\n10\n1\n{}\n",
                index * 100,
                r"\LA\lB".repeat(160)
            ));
        }
        source.push_str("0\nENDSEC\n0\nEOF\n");
        std::fs::write(&path, source).unwrap();
        let opened = open_document(path.to_string_lossy().into_owned()).unwrap();
        let mut cursor = 0;
        let mut seen = 0;
        loop {
            let payload = text_layout_batch(opened.session_id, cursor).unwrap();
            assert!(
                payload.len() <= 64 * 1024,
                "style bytes must be counted, not only text length"
            );
            let batch: serde_json::Value = serde_json::from_str(&payload).unwrap();
            let items = batch["items"].as_array().unwrap();
            assert_eq!(items.len(), 1);
            assert_eq!(
                items[0]["geometry"]["text_runs"].as_array().unwrap().len(),
                320
            );
            assert_eq!(items[0]["geometry"]["value"], "AB".repeat(160));
            let next = batch["next"].as_u64().unwrap();
            assert!(next > cursor);
            seen += items.len();
            cursor = next;
            if next == batch["total"].as_u64().unwrap() {
                break;
            }
        }
        assert_eq!(seen, 4);
        assert!(close_document(opened.session_id));
    }

    #[test]
    fn measured_text_layout_replaces_estimates_atomically_and_in_bounded_pages() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("aligned.dxf");
        let mut source = String::from(
            "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1021\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n",
        );
        for index in 0..70 {
            let x = index * 1000;
            source.push_str(&format!(
                "0\nTEXT\n8\n0\n10\n{x}\n20\n0\n11\n{}\n21\n0\n40\n10\n41\n0.1\n72\n3\n1\nI\n",
                x + 100
            ));
        }
        source.push_str("0\nENDSEC\n0\nEOF\n");
        std::fs::write(&path, source).unwrap();
        let opened = open_document(path.to_string_lossy().into_owned()).unwrap();
        let id = opened.session_id;
        let first: serde_json::Value =
            serde_json::from_str(&text_layout_batch(id, 0).unwrap()).unwrap();
        assert_eq!(first["items"].as_array().unwrap().len(), 64);
        assert_eq!(first["next"], 64);
        assert!(text_layout_batch(id, 71).is_err());
        assert!(finalize_text_layout(id).is_err());
        let prior: OpenedDocument =
            serde_json::from_str(&viewport_document(id, 45.0, 500.0, 55.0, 501.0).unwrap())
                .unwrap();
        let SceneDocument::TwoD(prior) = prior.scene else {
            panic!()
        };
        assert!(
            prior.entities.is_empty(),
            "old fitted-glyph estimate must reproduce the bug"
        );
        let mut cursor = 0;
        loop {
            let batch: serde_json::Value =
                serde_json::from_str(&text_layout_batch(id, cursor).unwrap()).unwrap();
            let packet: Vec<_> = batch["items"]
                .as_array()
                .unwrap()
                .iter()
                .map(|item| {
                    let x = item["index"].as_u64().unwrap() * 1000;
                    serde_json::json!({"id": item["id"], "index": item["index"],
                    "min_x": x, "max_x": x + 100, "min_y": -50, "max_y": 4000})
                })
                .collect();
            if cursor == 0 {
                let mut invalid = packet.clone();
                invalid[1]["id"] = serde_json::json!(u64::MAX);
                assert!(
                    apply_text_layout_bounds(id, serde_json::to_string(&invalid).unwrap()).is_err()
                );
                assert!(SESSIONS.read()[&id].text_layout_bounds.is_empty());
            }
            apply_text_layout_bounds(id, serde_json::to_string(&packet).unwrap()).unwrap();
            cursor = batch["next"].as_u64().unwrap();
            if cursor == batch["total"].as_u64().unwrap() {
                break;
            }
        }
        let summary: OpenedDocument =
            serde_json::from_str(&finalize_text_layout(id).unwrap()).unwrap();
        let SceneDocument::TwoD(summary) = summary.scene else {
            panic!()
        };
        assert_eq!(summary.bounds.unwrap().max.y, 4000.0);
        assert!(
            summary.entities.is_empty(),
            "summary must not transfer full geometry"
        );
        let updated: OpenedDocument =
            serde_json::from_str(&viewport_document(id, 45.0, 500.0, 55.0, 501.0).unwrap())
                .unwrap();
        let SceneDocument::TwoD(updated) = updated.scene else {
            panic!()
        };
        assert_eq!(updated.entities.len(), 1);
        assert!(close_document(id));
    }

    #[test]
    fn viewport_serialization_uses_spatial_index() {
        let session_id = u64::MAX - 1;
        let mut scene = Scene2D {
            layers: vec![
                cad_core::Layer {
                    id: 1,
                    name: "0".to_owned(),
                    visible: true,
                    color_argb: 0xffffffff,
                },
                cad_core::Layer {
                    id: 2,
                    name: "other".to_owned(),
                    visible: true,
                    color_argb: 0xffffffff,
                },
            ],
            entities: vec![
                Entity2D {
                    id: 1,
                    layer_id: 1,
                    color_argb: 0xffffffff,
                    stroke_width: 0.0,
                    filled: false,
                    dash: Vec::new(),
                    geometry: Entity2DGeometry::Line {
                        start: Point2::new(1.0, 1.0),
                        end: Point2::new(4.0, 5.0),
                    },
                },
                Entity2D {
                    id: 2,
                    layer_id: 1,
                    color_argb: 0xffffffff,
                    stroke_width: 0.0,
                    filled: false,
                    dash: Vec::new(),
                    geometry: Entity2DGeometry::Line {
                        start: Point2::new(100.0, 100.0),
                        end: Point2::new(100.0, 110.0),
                    },
                },
                Entity2D {
                    id: 3,
                    layer_id: 2,
                    color_argb: 0xffffffff,
                    stroke_width: 0.0,
                    filled: false,
                    dash: Vec::new(),
                    geometry: Entity2DGeometry::Line {
                        start: Point2::new(200.0, 200.0),
                        end: Point2::new(200.0, 220.0),
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
                frames: Vec::new(),
            },
            scene: SceneDocument::TwoD(scene.clone()),
            diagnostics: Vec::new(),
        };
        let statistics = build_entity_statistics(&document);
        SESSIONS.write().insert(
            session_id,
            DocumentSession {
                entity_kind_counts: statistics.0,
                layer_entity_kind_counts: statistics.1,
                entity_kind_lengths: statistics.2,
                layer_entity_kind_lengths: statistics.3,
                entity_kind_areas: statistics.4,
                layer_entity_kind_areas: statistics.5,
                document,
                spatial_index: Some(SceneIndex2D::build(&scene)),
                spatial_index_3d: None,
                text_layout_bounds: HashMap::new(),
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
        let counts = entity_count_summary(session_id, 1).unwrap().unwrap();
        assert_eq!(counts.entity_kind, "line");
        assert_eq!(counts.same_kind_in_layer, 2);
        assert_eq!(counts.same_kind_in_document, 3);
        assert_eq!(counts.same_kind_length_in_layer, Some(15.0));
        assert_eq!(counts.same_kind_length_in_document, Some(35.0));
        close_document(session_id);
    }

    #[test]
    fn entity_statistics_sum_only_valid_closed_areas() {
        let document = OpenedDocument {
            metadata: DocumentMetadata {
                format: FormatId::Dxf,
                display_name: "areas.dxf".to_owned(),
                fingerprint: "area-statistics".to_owned(),
                byte_length: 0,
                units: None,
                author: None,
                frames: Vec::new(),
            },
            scene: SceneDocument::TwoD(Scene2D {
                layers: vec![
                    cad_core::Layer {
                        id: 1,
                        name: "one".to_owned(),
                        visible: true,
                        color_argb: 0xffffffff,
                    },
                    cad_core::Layer {
                        id: 2,
                        name: "two".to_owned(),
                        visible: true,
                        color_argb: 0xffffffff,
                    },
                ],
                entities: vec![
                    Entity2D {
                        id: 1,
                        layer_id: 1,
                        color_argb: 0xffffffff,
                        stroke_width: 0.0,
                        filled: false,
                        dash: Vec::new(),
                        geometry: Entity2DGeometry::Circle {
                            center: Point2::new(0.0, 0.0),
                            radius: 2.0,
                        },
                    },
                    Entity2D {
                        id: 2,
                        layer_id: 2,
                        color_argb: 0xffffffff,
                        stroke_width: 0.0,
                        filled: false,
                        dash: Vec::new(),
                        geometry: Entity2DGeometry::Circle {
                            center: Point2::new(10.0, 0.0),
                            radius: 3.0,
                        },
                    },
                    Entity2D {
                        id: 3,
                        layer_id: 1,
                        color_argb: 0xffffffff,
                        stroke_width: 0.0,
                        filled: false,
                        dash: Vec::new(),
                        geometry: Entity2DGeometry::Polyline {
                            points: vec![
                                Point2::new(0.0, 0.0),
                                Point2::new(3.0, 0.0),
                                Point2::new(3.0, 2.0),
                                Point2::new(0.0, 2.0),
                            ],
                            closed: true,
                        },
                    },
                    Entity2D {
                        id: 4,
                        layer_id: 1,
                        color_argb: 0xffffffff,
                        stroke_width: 0.0,
                        filled: false,
                        dash: Vec::new(),
                        geometry: Entity2DGeometry::Polyline {
                            points: vec![
                                Point2::new(0.0, 0.0),
                                Point2::new(4.0, 4.0),
                                Point2::new(0.0, 4.0),
                                Point2::new(4.0, 0.0),
                            ],
                            closed: true,
                        },
                    },
                ],
                bounds: None,
            }),
            diagnostics: Vec::new(),
        };
        let statistics = build_entity_statistics(&document);

        assert!((statistics.4["circle"] - 13.0 * std::f64::consts::PI).abs() < 1e-12);
        assert!(
            (statistics.5[&(1, "circle".to_owned())] - 4.0 * std::f64::consts::PI).abs() < 1e-12
        );
        assert_eq!(statistics.4["polyline"], 6.0);
        assert_eq!(statistics.5[&(1, "polyline".to_owned())], 6.0);
    }

    #[test]
    fn batch_visibility_is_atomic_and_updates_layers_once() {
        let session_id = u64::MAX - 5;
        let scene = Scene2D {
            layers: vec![
                cad_core::Layer {
                    id: 1,
                    name: "walls".to_owned(),
                    visible: true,
                    color_argb: 0xffffffff,
                },
                cad_core::Layer {
                    id: 2,
                    name: "dimensions".to_owned(),
                    visible: false,
                    color_argb: 0xffffffff,
                },
            ],
            entities: Vec::new(),
            bounds: None,
        };
        let document = OpenedDocument {
            metadata: DocumentMetadata {
                format: FormatId::Dxf,
                display_name: "layers.dxf".to_owned(),
                fingerprint: "layers-test".to_owned(),
                byte_length: 0,
                units: None,
                author: None,
                frames: Vec::new(),
            },
            scene: SceneDocument::TwoD(scene),
            diagnostics: Vec::new(),
        };
        let statistics = build_entity_statistics(&document);
        SESSIONS.write().insert(
            session_id,
            DocumentSession {
                entity_kind_counts: statistics.0,
                layer_entity_kind_counts: statistics.1,
                entity_kind_lengths: statistics.2,
                layer_entity_kind_lengths: statistics.3,
                entity_kind_areas: statistics.4,
                layer_entity_kind_areas: statistics.5,
                document,
                spatial_index: None,
                spatial_index_3d: None,
                text_layout_bounds: HashMap::new(),
                annotations: AnnotationDocument::new("layers-test".to_owned()),
                undo: Vec::new(),
                redo: Vec::new(),
                camera: CameraState::default(),
            },
        );

        let json = set_visibilities(
            session_id,
            vec![
                VisibilityChange {
                    item_id: 1,
                    visible: false,
                },
                VisibilityChange {
                    item_id: 2,
                    visible: true,
                },
            ],
        )
        .unwrap();
        let opened: OpenedDocument = serde_json::from_str(&json).unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected 2D scene");
        };
        assert!(!scene.layers[0].visible);
        assert!(scene.layers[1].visible);

        assert!(set_visibilities(
            session_id,
            vec![
                VisibilityChange {
                    item_id: 1,
                    visible: true,
                },
                VisibilityChange {
                    item_id: 99,
                    visible: false,
                },
            ],
        )
        .is_err());
        let json = document_summary(session_id).unwrap();
        let opened: OpenedDocument = serde_json::from_str(&json).unwrap();
        let SceneDocument::TwoD(scene) = opened.scene else {
            panic!("expected 2D scene");
        };
        assert!(!scene.layers[0].visible);
        assert!(scene.layers[1].visible);
        close_document(session_id);
    }

    #[test]
    fn snap_finds_line_intersection_near_pointer() {
        let session_id = u64::MAX - 2;
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
                    stroke_width: 0.0,
                    filled: false,
                    dash: Vec::new(),
                    geometry: Entity2DGeometry::Line {
                        start: Point2::new(0.0, 0.0),
                        end: Point2::new(20.0, 20.0),
                    },
                },
                Entity2D {
                    id: 2,
                    layer_id: 1,
                    color_argb: 0xffffffff,
                    stroke_width: 0.0,
                    filled: false,
                    dash: Vec::new(),
                    geometry: Entity2DGeometry::Line {
                        start: Point2::new(0.0, 11.0),
                        end: Point2::new(10.0, 1.0),
                    },
                },
            ],
            bounds: None,
        };
        scene.recompute_bounds();
        let document = OpenedDocument {
            metadata: DocumentMetadata {
                format: FormatId::Dxf,
                display_name: "intersection.dxf".to_owned(),
                fingerprint: "intersection-test".to_owned(),
                byte_length: 0,
                units: None,
                author: None,
                frames: Vec::new(),
            },
            scene: SceneDocument::TwoD(scene.clone()),
            diagnostics: Vec::new(),
        };
        let statistics = build_entity_statistics(&document);
        SESSIONS.write().insert(
            session_id,
            DocumentSession {
                entity_kind_counts: statistics.0,
                layer_entity_kind_counts: statistics.1,
                entity_kind_lengths: statistics.2,
                layer_entity_kind_lengths: statistics.3,
                entity_kind_areas: statistics.4,
                layer_entity_kind_areas: statistics.5,
                document,
                spatial_index: Some(SceneIndex2D::build(&scene)),
                text_layout_bounds: HashMap::new(),
                spatial_index_3d: None,
                annotations: AnnotationDocument::new("intersection-test".to_owned()),
                undo: Vec::new(),
                redo: Vec::new(),
                camera: CameraState::default(),
            },
        );

        let result = snap(session_id, 5.7, 5.4, 1.0).unwrap().unwrap();
        assert_eq!(result.snap_kind, "intersection");
        assert!((result.x - 5.5).abs() < 1e-10);
        assert!((result.y - 5.5).abs() < 1e-10);

        // A boundary-taking tool can intentionally prefer the crossing even
        // when an endpoint is closer to the pointer inside the same aperture.
        let nearest = snap(session_id, 0.1, 0.1, 8.0).unwrap().unwrap();
        assert_eq!(nearest.snap_kind, "endpoint");
        let preferred = snap_intersection(session_id, 0.1, 0.1, 8.0)
            .unwrap()
            .expect("intersection remains available to area collection");
        assert_eq!(preferred.snap_kind, "intersection");
        assert!((preferred.x - 5.5).abs() < 1e-10);
        assert!((preferred.y - 5.5).abs() < 1e-10);
        close_document(session_id);
    }

    #[test]
    fn curve_intersections_cover_segments_and_circles() {
        let points = segment_circle_intersections(
            Point2::new(-2.0, 0.0),
            Point2::new(2.0, 0.0),
            Point2::new(0.0, 0.0),
            1.0,
        );
        assert_eq!(points.len(), 2);
        assert!(points.iter().any(|point| (point.x - 1.0).abs() < 1e-10));
        assert!(points.iter().any(|point| (point.x + 1.0).abs() < 1e-10));

        let points = circle_intersections(Point2::new(0.0, 0.0), 5.0, Point2::new(8.0, 0.0), 5.0);
        assert_eq!(points.len(), 2);
        assert!(points.iter().all(|point| (point.x - 4.0).abs() < 1e-10));
    }

    #[test]
    fn nearest_intersection_is_not_hidden_by_dense_earlier_entities() {
        let mut geometries = (0..300)
            .map(|_| Entity2DGeometry::Line {
                start: Point2::new(-1.0, 0.8),
                end: Point2::new(1.0, 0.8),
            })
            .collect::<Vec<_>>();
        geometries.push(Entity2DGeometry::Line {
            start: Point2::new(-1.0, 0.0),
            end: Point2::new(1.0, 0.0),
        });
        geometries.push(Entity2DGeometry::Line {
            start: Point2::new(0.0, -1.0),
            end: Point2::new(0.0, 1.0),
        });
        let entities = geometries
            .iter()
            .enumerate()
            .map(|(index, geometry)| (index as u64 + 1, geometry))
            .collect::<Vec<_>>();

        let result = nearest_intersection(&entities, Point2::new(0.0, 0.0), 1.0)
            .expect("the closest crossing should survive the candidate cap");
        assert_eq!(result.2, "intersection");
        assert!(result.1.x.abs() < 1e-10);
        assert!(result.1.y.abs() < 1e-10);
    }

    #[test]
    fn arc_hit_distance_does_not_treat_the_arc_as_a_full_circle() {
        let arc = Entity2DGeometry::Arc {
            center: Point2::new(0.0, 0.0),
            radius: 10.0,
            start_angle: 0.0,
            end_angle: std::f64::consts::FRAC_PI_2,
        };
        let coordinate = std::f64::consts::FRAC_1_SQRT_2 * 10.0;
        let on_arc = Point2::new(coordinate, coordinate);
        assert!(entity_distance(&arc, on_arc).unwrap() < 1e-10);
        assert!(entity_distance(&arc, Point2::new(-10.0, 0.0)).unwrap() > 14.0);
    }

    #[test]
    fn transverse_boundary_is_not_lost_behind_closer_parallel_hatch_lines() {
        for origin in [0.0, 1e12] {
            let mut geometry = (0..600)
                .map(|i| Entity2DGeometry::Line {
                    start: Point2::new(origin - 2.0, origin + 0.01 + i as f64 / 10000.0),
                    end: Point2::new(origin + 2.0, origin + 0.01 + i as f64 / 10000.0),
                })
                .collect::<Vec<_>>();
            geometry.push(Entity2DGeometry::Line {
                start: Point2::new(origin + 0.7, origin - 2.0),
                end: Point2::new(origin + 0.7, origin + 2.0),
            });
            let entities = geometry
                .iter()
                .enumerate()
                .map(|(i, g)| (i as u64, g))
                .collect::<Vec<_>>();
            let hit = nearest_intersection(&entities, Point2::new(origin, origin), 1.0).unwrap();
            let epsilon = (origin.abs() * f64::EPSILON * 2.0).max(1e-12);
            assert!((hit.1.x - (origin + 0.7)).abs() <= epsilon);
            assert!((hit.1.y - (origin + 0.01)).abs() <= epsilon);
            assert_eq!(hit.0, 0);
        }
    }

    #[test]
    fn indexed_crossings_match_exhaustive_pairs_in_dense_mixed_geometry() {
        let mut geometries = (0..280)
            .map(|i| {
                let a = i as f64 * 0.317;
                Entity2DGeometry::Line {
                    start: Point2::new(a.cos() * 3.0, a.sin() * 3.0),
                    end: Point2::new((a + 0.3).sin() * 4.0, (a + 0.2).cos() * 4.0),
                }
            })
            .collect::<Vec<_>>();
        for i in 0..20 {
            geometries.push(Entity2DGeometry::Arc {
                center: Point2::new(i as f64 * 0.1 - 1.0, 0.0),
                radius: 0.3 + i as f64 * 0.02,
                start_angle: 0.0,
                end_angle: std::f64::consts::PI,
            });
        }
        let entities = geometries
            .iter()
            .enumerate()
            .map(|(i, g)| (i as u64, g))
            .collect::<Vec<_>>();
        for i in 0..20 {
            let target = Point2::new(i as f64 * 0.13 - 1.0, 0.123);
            let mut curves = Vec::new();
            for (id, geometry) in &entities {
                append_nearby_curves(&mut curves, *id, geometry, target, 1.0);
            }
            let mut expected = f64::INFINITY;
            for (a, first) in curves.iter().enumerate() {
                for second in &curves[a + 1..] {
                    for point in curve_intersections(*first, *second) {
                        if first.contains(point) && second.contains(point) {
                            let distance = distance_2d(target, point);
                            if distance <= 1.0 {
                                expected = expected.min(distance);
                            }
                        }
                    }
                }
            }
            let result = nearest_intersection(&entities, target, 1.0).unwrap();
            assert!((result.3 - expected).abs() < 1e-12, "target {target:?}");
        }
    }

    #[test]
    fn invalid_pick_inputs_return_errors_without_spatial_index_panics() {
        for (x, y, tolerance) in [
            (f64::NAN, 0.0, 1.0),
            (0.0, f64::INFINITY, 1.0),
            (0.0, 0.0, f64::NAN),
            (f64::MAX, 0.0, f64::MAX),
        ] {
            assert!(hit_test(0, x, y, tolerance).is_err());
            assert!(snap(0, x, y, tolerance).is_err());
            assert!(snap_intersection(0, x, y, tolerance).is_err());
        }
    }

    #[test]
    fn long_polyline_snap_keeps_the_exact_nearest_source_vertex() {
        let geometry = Entity2DGeometry::Polyline {
            points: (0..100_000)
                .map(|i| Point2::new(1e12 + i as f64 * 0.25, 1e12))
                .collect(),
            closed: false,
        };
        let target = Point2::new(1e12 + 99999.0 * 0.25, 1e12);
        let result = nearest_snap_point(37, &geometry, target, 0.01).unwrap();
        assert_eq!(result, (37, target, "vertex".to_owned(), 0.0));
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
                frames: Vec::new(),
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
