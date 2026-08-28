use crate::{Bounds2, Bounds3, DocumentMetadata, FormatDiagnostic, Point2, Point3};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Layer {
    pub id: u64,
    pub name: String,
    pub visible: bool,
    pub color_argb: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Entity2DGeometry {
    Point {
        position: Point2,
    },
    Line {
        start: Point2,
        end: Point2,
    },
    Polyline {
        points: Vec<Point2>,
        closed: bool,
    },
    Circle {
        center: Point2,
        radius: f64,
    },
    Arc {
        center: Point2,
        radius: f64,
        start_angle: f64,
        end_angle: f64,
    },
    Text {
        origin: Point2,
        value: String,
        height: f64,
        rotation: f64,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entity2D {
    pub id: u64,
    pub layer_id: u64,
    pub color_argb: u32,
    pub geometry: Entity2DGeometry,
}

impl Entity2D {
    pub fn bounds(&self) -> Option<Bounds2> {
        use Entity2DGeometry::*;
        match &self.geometry {
            Point { position } => Bounds2::from_points([*position]),
            Line { start, end } => Bounds2::from_points([*start, *end]),
            Polyline { points, .. } => Bounds2::from_points(points.iter().copied()),
            Circle { center, radius } | Arc { center, radius, .. } => Some(Bounds2 {
                min: Point2::new(center.x - radius, center.y - radius),
                max: Point2::new(center.x + radius, center.y + radius),
            }),
            Text {
                origin,
                height,
                value,
                ..
            } => Some(Bounds2 {
                min: *origin,
                max: Point2::new(
                    origin.x + height * value.chars().count() as f64 * 0.65,
                    origin.y + height,
                ),
            }),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Scene2D {
    pub layers: Vec<Layer>,
    pub entities: Vec<Entity2D>,
    pub bounds: Option<Bounds2>,
}

impl Scene2D {
    pub fn recompute_bounds(&mut self) {
        self.bounds = self
            .entities
            .iter()
            .filter_map(Entity2D::bounds)
            .fold(None, |acc, next| {
                Some(match acc {
                    None => next,
                    Some(mut current) => {
                        current.include(next.min);
                        current.include(next.max);
                        current
                    }
                })
            });
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Material3D {
    pub name: String,
    pub base_color: [f32; 4],
    pub metallic: f32,
    pub roughness: f32,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Mesh3D {
    pub id: u64,
    pub name: String,
    pub positions: Vec<Point3>,
    pub normals: Vec<[f32; 3]>,
    pub indices: Vec<u32>,
    pub material_index: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AssemblyNode {
    pub id: u64,
    pub name: String,
    pub visible: bool,
    pub mesh_ids: Vec<u64>,
    pub children: Vec<AssemblyNode>,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct MeshStats {
    pub mesh_count: u64,
    pub vertex_count: u64,
    pub triangle_count: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Scene3D {
    pub root_nodes: Vec<AssemblyNode>,
    pub meshes: Vec<Mesh3D>,
    pub materials: Vec<Material3D>,
    pub bounds: Option<Bounds3>,
    pub stats: MeshStats,
}

impl Scene3D {
    pub fn recompute_stats(&mut self) {
        self.stats = MeshStats {
            mesh_count: self.meshes.len() as u64,
            vertex_count: self
                .meshes
                .iter()
                .map(|mesh| mesh.positions.len() as u64)
                .sum(),
            triangle_count: self
                .meshes
                .iter()
                .map(|mesh| mesh.indices.len() as u64 / 3)
                .sum(),
        };
        self.bounds = self
            .meshes
            .iter()
            .flat_map(|mesh| mesh.positions.iter().copied())
            .fold(None, |acc, point| {
                Some(match acc {
                    None => Bounds3 {
                        min: point,
                        max: point,
                    },
                    Some(mut bounds) => {
                        bounds.include(point);
                        bounds
                    }
                })
            });
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PagedScene {
    pub page_count: u32,
    pub current_page: u32,
    pub width_points: f64,
    pub height_points: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "scene_kind", content = "scene", rename_all = "snake_case")]
pub enum SceneDocument {
    TwoD(Scene2D),
    ThreeD(Scene3D),
    Paged(PagedScene),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenedDocument {
    pub metadata: DocumentMetadata,
    pub scene: SceneDocument,
    pub diagnostics: Vec<FormatDiagnostic>,
}
