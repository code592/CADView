use crate::{Bounds2, Bounds3, DocumentMetadata, FormatDiagnostic, Point2, Point3};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Layer {
    pub id: u64,
    pub name: String,
    pub visible: bool,
    pub color_argb: u32,
}

/// Linear XY projection of a text's 3D plane after its local rotation.
/// The insertion point is already in WCS; no translation is applied here.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct TextPlane2D {
    pub xx: f64,
    pub xy: f64,
    pub yx: f64,
    pub yy: f64,
}

impl TextPlane2D {
    pub fn apply(self, point: Point2) -> Point2 {
        Point2::new(
            self.xx * point.x + self.xy * point.y,
            self.yx * point.x + self.yy * point.y,
        )
    }
}

/// UTF-16 ranges match Flutter's paragraph indices, not UTF-8 byte offsets.
/// Styles apply to already-decoded text, including supplementary characters.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TextRun2D {
    pub start: u32,
    pub end: u32,
    pub style: TextStyle2D,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TextStyle2D {
    pub font_family: Option<String>,
    pub height_factor: f64,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub overline: bool,
    pub strike_through: bool,
}

impl Default for TextStyle2D {
    fn default() -> Self {
        Self {
            font_family: None,
            height_factor: 1.0,
            bold: false,
            italic: false,
            underline: false,
            overline: false,
            strike_through: false,
        }
    }
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
        /// CAD TEXT/MTEXT uses capital height; SVG font-size uses em height.
        #[serde(default)]
        height_reference: TextHeightReference2D,
        rotation: f64,
        /// CAD width factor. Kept separate from font size so fitted title-block
        /// labels retain their intended proportions.
        #[serde(default = "default_text_width_factor")]
        width_factor: f64,
        #[serde(default)]
        oblique_angle: f64,
        #[serde(default)]
        horizontal_alignment: TextHorizontalAlignment2D,
        #[serde(default)]
        vertical_alignment: TextVerticalAlignment2D,
        /// Width between the two TEXT alignment points for Aligned/Fit text.
        #[serde(default)]
        target_width: Option<f64>,
        /// Aligned TEXT scales height with width; Fit TEXT keeps height fixed.
        #[serde(default)]
        uniform_fit: bool,
        /// MTEXT paragraph width in drawing units, separate from TEXT fitting.
        #[serde(default)]
        wrap_width: Option<f64>,
        /// MTEXT group 44 factor and group 73 policy, separate from font height.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        line_spacing: Option<MTextLineSpacing2D>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        columns: Option<MTextColumns2D>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        background: Option<MTextBackground2D>,
        #[serde(default)]
        mirrored_x: bool,
        #[serde(default)]
        mirrored_y: bool,
        /// A licensed bundled family or an installed TrueType family. SHX file
        /// names are intentionally not exposed as font-family names.
        #[serde(default)]
        font_family: Option<String>,
        /// SHX font files of the source text style. They are not
        /// redistributable; the renderer uses them to emulate SHX proportions
        /// with bundled substitute fonts.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        shx: Option<ShxFonts2D>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        plane: Option<TextPlane2D>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        text_runs: Vec<TextRun2D>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        text_warnings: Vec<String>,
    },
}

/// Lowercase SHX file names (primary and big font) of a CAD text style.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShxFonts2D {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub font: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub big_font: Option<String>,
}

impl ShxFonts2D {
    /// SHX names from a style's primary and big font files. A primary file
    /// without an extension (for example `txt`) is an SHX font as well.
    pub fn from_style(font_file: &str, big_font_file: &str) -> Option<Self> {
        fn shx(file: &str, bare_is_shx: bool) -> Option<String> {
            let name = file.trim().replace('\\', "/");
            let name = name
                .rsplit('/')
                .next()
                .unwrap_or_default()
                .to_ascii_lowercase();
            if name.is_empty() {
                return None;
            }
            match name.rsplit_once('.') {
                Some((_, extension)) if extension == "shx" => Some(name),
                None if bare_is_shx => Some(format!("{name}.shx")),
                _ => None,
            }
        }
        let fonts = Self {
            font: shx(font_file, true),
            big_font: shx(big_font_file, true),
        };
        (fonts.font.is_some() || fonts.big_font.is_some()).then_some(fonts)
    }
}

fn default_text_width_factor() -> f64 {
    1.0
}

/// Validated column flow in original drawing units. UTF-16 break offsets point
/// at the decoded newline that represents a manual MTEXT `\\N` control.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MTextColumns2D {
    pub count: u32,
    pub width: f64,
    pub gutter: f64,
    pub defined_height: f64,
    pub heights: Vec<f64>,
    pub flow_reversed: bool,
    pub auto_height: bool,
    pub manual_breaks: Vec<u32>,
}

/// MTEXT decoration is separate from glyph layout. Scale adds a margin of
/// (scale - 1) * nominal CAD text height, not a percentage of paragraph width.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct MTextBackground2D {
    /// Multi-column decoration requires column-aware layout; never mask a
    /// flattened paragraph's gutters as if it were one genuine rectangle.
    pub layout_supported: bool,
    pub fill: bool,
    pub frame: bool,
    pub scale: f64,
    pub color_mode: MTextBackgroundColor2D,
    pub color_argb: u32,
    pub transparency: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MTextBackgroundColor2D {
    Explicit,
    Canvas,
    ByLayer,
    ByBlock,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TextHeightReference2D {
    #[default]
    CapHeight,
    Em,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct MTextLineSpacing2D {
    pub factor: f64,
    pub style: MTextLineSpacingStyle2D,
}

impl Default for MTextLineSpacing2D {
    fn default() -> Self {
        Self {
            factor: 1.0,
            style: MTextLineSpacingStyle2D::AtLeast,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MTextLineSpacingStyle2D {
    #[default]
    AtLeast,
    Exact,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TextHorizontalAlignment2D {
    #[default]
    Left,
    Center,
    Right,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TextVerticalAlignment2D {
    #[default]
    Baseline,
    Bottom,
    Middle,
    Top,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entity2D {
    pub id: u64,
    pub layer_id: u64,
    pub color_argb: u32,
    /// Polyline width in drawing units. A value of zero uses a cosmetic
    /// one-pixel stroke in the preview renderer.
    #[serde(default)]
    pub stroke_width: f64,
    /// Whether a closed path represents filled CAD geometry (for example a
    /// DWG SOLID dimension arrowhead) rather than an outline-only polyline.
    #[serde(default)]
    pub filled: bool,
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
                width_factor,
                target_width,
                uniform_fit,
                wrap_width,
                line_spacing,
                columns,
                background,
                horizontal_alignment,
                vertical_alignment,
                rotation,
                oblique_angle,
                mirrored_x,
                mirrored_y,
                plane,
                text_runs,
                ..
            } => {
                let height = height.abs()
                    * text_runs
                        .iter()
                        .fold(1.0_f64, |maximum, run| maximum.max(run.style.height_factor));
                let natural_width = {
                    // CJK glyphs commonly occupy a full em. Conservative text
                    // bounds prevent a visible tail from being culled merely
                    // because its insertion point has moved off-screen.
                    height
                        * value
                            .lines()
                            .map(|line| line.chars().count())
                            .max()
                            .unwrap_or(0) as f64
                        * 1.5
                        * width_factor.abs()
                };
                let width = columns.as_ref().map_or_else(
                    || {
                        target_width.map(f64::abs).unwrap_or_else(|| {
                            wrap_width
                                .filter(|width| width.is_finite() && *width > 0.0)
                                .map_or(natural_width, |width| width.max(height * 1.5))
                        })
                    },
                    |columns| {
                        (columns.width * f64::from(columns.count)
                            + columns.gutter * f64::from(columns.count.saturating_sub(1)))
                        .max(height * 1.5)
                    },
                );
                let left = match horizontal_alignment {
                    TextHorizontalAlignment2D::Left => 0.0,
                    TextHorizontalAlignment2D::Center => -width * 0.5,
                    TextHorizontalAlignment2D::Right => -width,
                };
                // No platform shaper runs in the Rust spatial index. Use a
                // conservative multiline envelope including font ascent,
                // descenders and combining marks; Flutter uses actual layout.
                let lines = value.bytes().filter(|byte| *byte == b'\n').count() + 1;
                // Estimate wrapped rows from conservative advances, allowing
                // word-boundary slack. Treating every scalar as a row even in
                // a wide paragraph makes fit-to-drawing zoom out dramatically.
                // Flutter still uses the actual shaped paragraph for clipping.
                let lines = wrap_width
                    .filter(|width| width.is_finite() && *width > 0.0)
                    .map_or(lines, |width| {
                        value
                            .split('\n')
                            .map(|line| {
                                let chars = line.chars().count().max(1);
                                let estimated_width =
                                    height * chars as f64 * 1.5 * width_factor.abs();
                                ((estimated_width / width).ceil() as usize)
                                    .saturating_mul(2)
                                    .clamp(1, chars)
                            })
                            .sum::<usize>()
                    });
                let bound_height = if *uniform_fit {
                    height.max(target_width.unwrap_or(height).abs())
                } else {
                    height
                };
                let spacing = line_spacing.map_or(2.0, |spacing| {
                    if spacing.factor.is_finite() && (0.25..=4.0).contains(&spacing.factor) {
                        (5.0 / 3.0 * spacing.factor).max(2.0)
                    } else {
                        2.0
                    }
                });
                let text_height = (bound_height * lines as f64 * spacing).max(
                    columns.as_ref().map_or(0.0, |columns| {
                        columns
                            .heights
                            .iter()
                            .copied()
                            .fold(columns.defined_height, f64::max)
                    }),
                );
                let bottom = match vertical_alignment {
                    TextVerticalAlignment2D::Baseline | TextVerticalAlignment2D::Bottom => 0.0,
                    TextVerticalAlignment2D::Middle => -text_height * 0.5,
                    TextVerticalAlignment2D::Top => -text_height,
                };
                let (sin, cos) = rotation.sin_cos();
                let skew = if oblique_angle.is_finite() {
                    oblique_angle.tan()
                } else {
                    0.0
                };
                let mirror_x = if *mirrored_x { -1.0 } else { 1.0 };
                let mirror_y = if *mirrored_y { -1.0 } else { 1.0 };
                let padding = background.map_or(height, |background| {
                    if background.layout_supported {
                        height.max(self.text_background_margin(background))
                    } else {
                        height
                    }
                });
                Bounds2::from_points(
                    [
                        (left - padding, bottom - padding),
                        (left + width + padding, bottom - padding),
                        (left + width + padding, bottom + text_height + padding),
                        (left - padding, bottom + text_height + padding),
                    ]
                    .map(|(x, y)| {
                        let y = y * mirror_y;
                        let x = x * mirror_x + skew * y;
                        let offset = Point2::new(x * cos - y * sin, x * sin + y * cos);
                        let offset = plane.map_or(offset, |plane| plane.apply(offset));
                        Point2::new(origin.x + offset.x, origin.y + offset.y)
                    }),
                )
            }
        }
    }

    fn text_background_margin(&self, background: MTextBackground2D) -> f64 {
        match &self.geometry {
            Entity2DGeometry::Text { height, .. }
                if background.scale.is_finite() && (1.0..=5.0).contains(&background.scale) =>
            {
                height.abs() * (background.scale - 1.0)
            }
            _ => 0.0,
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
    #[serde(default)]
    pub surface_area: Option<f64>,
    #[serde(default)]
    pub closed_manifold: Option<bool>,
    #[serde(default)]
    pub enclosed_volume: Option<f64>,
    #[serde(default)]
    pub volume_centroid: Option<Point3>,
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

#[cfg(test)]
mod text_bounds_tests {
    use super::*;
    use crate::SceneIndex2D;

    #[test]
    fn multiline_mirrored_text_survives_spatial_viewport_query() {
        let entity = Entity2D {
            id: 1,
            layer_id: 0,
            color_argb: 0xffffffff,
            stroke_width: 0.0,
            filled: false,
            geometry: Entity2DGeometry::Text {
                origin: Point2::new(105.0, 0.0),
                value: "中文\nالعربية\n⌀ 120".into(),
                height: 20.0,
                height_reference: TextHeightReference2D::CapHeight,
                rotation: 0.0,
                width_factor: 1.0,
                oblique_angle: 0.2,
                horizontal_alignment: TextHorizontalAlignment2D::Left,
                vertical_alignment: TextVerticalAlignment2D::Top,
                target_width: None,
                uniform_fit: false,
                wrap_width: None,
                line_spacing: None,
                columns: None,
                background: None,
                mirrored_x: true,
                mirrored_y: false,
                font_family: None,
                shx: None,
                text_runs: Vec::new(),
                text_warnings: Vec::new(),
                plane: None,
            },
        };
        let bounds = entity.bounds().unwrap();
        assert!(bounds.min.x < 100.0);
        assert!(bounds.min.y < -60.0);
        let scene = Scene2D {
            entities: vec![entity],
            ..Default::default()
        };
        let index = SceneIndex2D::build(&scene);
        assert_eq!(
            index.query(Bounds2 {
                min: Point2::new(0.0, -60.0),
                max: Point2::new(100.0, 0.0)
            }),
            vec![1]
        );
        let border = Bounds2 {
            min: Point2::new(100.0, 60.0),
            max: Point2::new(110.0, 65.0),
        };
        assert!(index.query(border).is_empty());
        let mut decorated = scene.entities[0].clone();
        if let Entity2DGeometry::Text { background, .. } = &mut decorated.geometry {
            *background = Some(MTextBackground2D {
                layout_supported: true,
                fill: true,
                frame: false,
                scale: 5.0,
                color_mode: MTextBackgroundColor2D::Canvas,
                color_argb: 0,
                transparency: 0,
            });
        }
        let masked_index = SceneIndex2D::build(&Scene2D {
            entities: vec![decorated],
            ..Default::default()
        });
        assert_eq!(
            masked_index.query(border),
            vec![1],
            "The visible mask border must not be culled with the text origin"
        );
    }
}
