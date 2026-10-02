use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FormatId {
    Dxf,
    Dwg,
    Pdf,
    Svg,
    Stl,
    Obj,
    Gltf,
    Glb,
    ThreeMf,
    Step,
    Iges,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SceneKind {
    TwoD,
    ThreeD,
    Paged,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SupportLevel {
    Production,
    Beta,
    Experimental,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FormatCapabilities {
    pub format: FormatId,
    pub display_name: String,
    pub extensions: Vec<String>,
    pub scene_kind: SceneKind,
    pub support_level: SupportLevel,
    pub available: bool,
    pub can_stream: bool,
    pub can_measure: bool,
    pub can_select_topology: bool,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Point2 {
    pub x: f64,
    pub y: f64,
}

impl Point2 {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Point3 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl Point3 {
    pub const fn new(x: f64, y: f64, z: f64) -> Self {
        Self { x, y, z }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Bounds2 {
    pub min: Point2,
    pub max: Point2,
}

impl Bounds2 {
    pub fn from_points(points: impl IntoIterator<Item = Point2>) -> Option<Self> {
        let mut iter = points.into_iter();
        let first = iter.next()?;
        let mut bounds = Self {
            min: first,
            max: first,
        };
        for point in iter {
            bounds.include(point);
        }
        Some(bounds)
    }

    pub fn include(&mut self, point: Point2) {
        self.min.x = self.min.x.min(point.x);
        self.min.y = self.min.y.min(point.y);
        self.max.x = self.max.x.max(point.x);
        self.max.y = self.max.y.max(point.y);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Bounds3 {
    pub min: Point3,
    pub max: Point3,
}

impl Bounds3 {
    pub fn from_points(points: impl IntoIterator<Item = Point3>) -> Option<Self> {
        let mut iter = points.into_iter();
        let first = iter.next()?;
        let mut bounds = Self {
            min: first,
            max: first,
        };
        for point in iter {
            bounds.include(point);
        }
        Some(bounds)
    }

    pub fn include(&mut self, point: Point3) {
        self.min.x = self.min.x.min(point.x);
        self.min.y = self.min.y.min(point.y);
        self.min.z = self.min.z.min(point.z);
        self.max.x = self.max.x.max(point.x);
        self.max.y = self.max.y.max(point.y);
        self.max.z = self.max.z.max(point.z);
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenRequest {
    pub path: PathBuf,
    pub display_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DocumentMetadata {
    pub format: FormatId,
    pub display_name: String,
    pub fingerprint: String,
    pub byte_length: u64,
    pub units: Option<String>,
    pub author: Option<String>,
    /// Sheet borders of a 2D drawing, used to split image/PDF exports.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub frames: Vec<crate::DrawingFrame>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticSeverity {
    Info,
    Warning,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FormatDiagnostic {
    pub code: String,
    pub message: String,
    pub severity: DiagnosticSeverity,
    pub entity_id: Option<u64>,
}

/// Stable path from a document root to a selected layer/entity or assembly item.
/// IDs are preferred; names allow a best-effort recovery when the source changed.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SelectionPath {
    pub node_ids: Vec<u64>,
    pub names: Vec<String>,
    pub entity_id: Option<u64>,
    pub topology_id: Option<String>,
}

pub fn fingerprint(bytes: &[u8]) -> String {
    blake3::hash(bytes).to_hex().to_string()
}

pub fn fingerprint_path(path: &std::path::Path) -> std::io::Result<String> {
    use std::io::Read;

    let mut file = std::fs::File::open(path)?;
    let mut hasher = blake3::Hasher::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher.finalize().to_hex().to_string())
}
