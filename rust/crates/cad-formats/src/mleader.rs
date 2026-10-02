//! Format-independent MULTILEADER and ACAD_TABLE model shared by the DXF and
//! DWG adapters. Leader lines, doglegs and arrowheads become geometry here;
//! MTEXT content and block content are handed back to each adapter so they go
//! through its existing MTEXT and INSERT normalization.

use crate::curves::{tessellate_spline, SplineSource};
use cad_core::{Entity2DGeometry, Point2};

/// A raw AutoCAD CmColor (used by MULTILEADER): the high byte selects
/// ByLayer (0xC0), ByBlock (0xC1), true color (0xC2) or ACI (0xC3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CmColor {
    ByLayer,
    ByBlock,
    Rgb(u32),
    Aci(u8),
}

impl CmColor {
    pub fn from_raw(raw: i64) -> Self {
        let raw = raw as u32;
        match raw >> 24 {
            0xC1 => Self::ByBlock,
            0xC2 => Self::Rgb(raw & 0xffffff),
            0xC3 => match raw & 0xff {
                0 => Self::ByBlock,
                index @ 1..=255 => Self::Aci(index as u8),
                _ => Self::ByLayer,
            },
            _ => Self::ByLayer,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LeaderPath {
    Invisible,
    Straight,
    Spline,
}

#[derive(Debug, Clone)]
pub(crate) struct LeaderLine {
    /// WCS vertices starting at the arrowhead.
    pub points: Vec<[f64; 3]>,
}

#[derive(Debug, Clone)]
pub(crate) struct LeaderBranch {
    /// Each line ends at the branch's last leader point.
    pub lines: Vec<LeaderLine>,
    pub last_point: Option<[f64; 3]>,
    pub dogleg: [f64; 3],
    pub dogleg_length: f64,
}

#[derive(Debug, Clone)]
pub(crate) struct MLeaderText {
    /// MTEXT-formatted content.
    pub value: String,
    pub location: [f64; 3],
    pub direction: [f64; 3],
    pub normal: [f64; 3],
    pub height: f64,
    pub width: f64,
    pub line_spacing_factor: f64,
    /// 1 = left, 2 = center, 3 = right; `location` is the top of the text box.
    pub alignment: i16,
    pub style_handle: Option<u64>,
    pub color: CmColor,
}

#[derive(Debug, Clone)]
pub(crate) struct MLeaderBlock {
    pub block_handle: u64,
    pub location: [f64; 3],
    pub normal: [f64; 3],
    pub scale: [f64; 3],
    pub rotation: f64,
    pub color: CmColor,
}

#[derive(Debug, Clone)]
pub(crate) struct MLeaderModel {
    pub branches: Vec<LeaderBranch>,
    pub path: LeaderPath,
    pub line_color: CmColor,
    pub dogleg_enabled: bool,
    pub arrowhead_size: f64,
    /// Handle of a custom arrowhead block; None is the default closed fill.
    pub arrowhead_handle: Option<u64>,
    pub text: Option<MLeaderText>,
    pub block: Option<MLeaderBlock>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Arrowhead {
    ClosedFilled,
    None,
}

/// The block names AutoCAD uses for arrowheads that draw nothing.
pub(crate) fn arrowhead_kind(block_name: Option<&str>) -> Arrowhead {
    match block_name.map(|name| name.trim().to_ascii_uppercase()) {
        Some(name) if name == "_NONE" || name == "_ORIGIN2" || name == "_SMALL" => Arrowhead::None,
        _ => Arrowhead::ClosedFilled,
    }
}

fn xy(point: [f64; 3]) -> Point2 {
    Point2::new(point[0], point[1])
}

/// Leader lines, doglegs and arrowheads as (geometry, filled) pairs. Custom
/// arrowhead blocks other than the "none" family are drawn as the default
/// closed filled arrow (width one third of its length).
pub(crate) fn leader_geometry(
    model: &MLeaderModel,
    arrowhead: Arrowhead,
) -> Vec<(Entity2DGeometry, bool)> {
    let mut output = Vec::new();
    for branch in &model.branches {
        if model.path != LeaderPath::Invisible {
            for line in &branch.lines {
                let mut vertices = line.points.clone();
                if let Some(last) = branch.last_point {
                    if vertices.last() != Some(&last) {
                        vertices.push(last);
                    }
                }
                if vertices.len() < 2 {
                    continue;
                }
                let points = if model.path == LeaderPath::Spline && vertices.len() > 2 {
                    tessellate_spline(&SplineSource {
                        degree: 3,
                        knots: &[],
                        control_points: &[],
                        weights: &[],
                        fit_points: &vertices,
                        closed: false,
                    })
                } else {
                    vertices.iter().copied().map(xy).collect()
                };
                if arrowhead == Arrowhead::ClosedFilled {
                    if let Some(arrow) = arrow(points[0], points[1], model.arrowhead_size) {
                        output.push((arrow, true));
                    }
                }
                output.push((
                    Entity2DGeometry::Polyline {
                        points,
                        closed: false,
                    },
                    false,
                ));
            }
        }
        let length = branch.dogleg_length;
        let vector = branch.dogleg;
        let norm = (vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]).sqrt();
        // Leader type "none" hides the whole leader, landing included.
        let dogleg = model.dogleg_enabled && model.path != LeaderPath::Invisible;
        if let (true, Some(start)) = (dogleg, branch.last_point) {
            if length.is_finite() && length > 0.0 && norm.is_finite() && norm > 0.0 {
                let end = [0, 1, 2].map(|axis| start[axis] + vector[axis] / norm * length);
                output.push((
                    Entity2DGeometry::Line {
                        start: xy(start),
                        end: xy(end),
                    },
                    false,
                ));
            }
        }
    }
    output
}

fn arrow(tip: Point2, toward: Point2, size: f64) -> Option<Entity2DGeometry> {
    let (dx, dy) = (toward.x - tip.x, toward.y - tip.y);
    let length = dx.hypot(dy);
    if !size.is_finite() || size <= 0.0 || length <= 0.0 {
        return None;
    }
    let (ux, uy) = (dx / length, dy / length);
    let base = Point2::new(tip.x + ux * size, tip.y + uy * size);
    let half = size / 6.0;
    Some(Entity2DGeometry::Polyline {
        points: vec![
            tip,
            Point2::new(base.x - uy * half, base.y + ux * half),
            Point2::new(base.x + uy * half, base.y - ux * half),
        ],
        closed: true,
    })
}

/// Rotation (radians, in the entity OCS) of a table whose X axis follows the
/// WCS [direction]: the direction expressed in the OCS of [normal].
pub(crate) fn table_rotation(direction: [f64; 3], axes: [[f64; 3]; 3]) -> f64 {
    let x = direction[0] * axes[0][0] + direction[1] * axes[0][1] + direction[2] * axes[0][2];
    let y = direction[0] * axes[1][0] + direction[1] * axes[1][1] + direction[2] * axes[1][2];
    if x == 0.0 && y == 0.0 {
        0.0
    } else {
        y.atan2(x)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cm_colors_decode_their_method_byte() {
        assert_eq!(CmColor::from_raw(0xC000_0000), CmColor::ByLayer);
        assert_eq!(CmColor::from_raw(0xC100_0000), CmColor::ByBlock);
        assert_eq!(CmColor::from_raw(0xC212_3456), CmColor::Rgb(0x123456));
        assert_eq!(CmColor::from_raw(0xC300_0001), CmColor::Aci(1));
        // Signed 32-bit storage of the same value.
        assert_eq!(CmColor::from_raw(-1_023_410_174), CmColor::Aci(2));
    }

    #[test]
    fn straight_leader_has_arrow_line_and_dogleg() {
        let model = MLeaderModel {
            branches: vec![LeaderBranch {
                lines: vec![LeaderLine {
                    points: vec![[0.0, 0.0, 0.0], [10.0, 10.0, 0.0]],
                }],
                last_point: Some([12.0, 10.0, 0.0]),
                dogleg: [1.0, 0.0, 0.0],
                dogleg_length: 3.0,
            }],
            path: LeaderPath::Straight,
            line_color: CmColor::ByLayer,
            dogleg_enabled: true,
            arrowhead_size: 2.0,
            arrowhead_handle: None,
            text: None,
            block: None,
        };
        let geometry = leader_geometry(&model, Arrowhead::ClosedFilled);
        assert_eq!(geometry.len(), 3);
        let (Entity2DGeometry::Polyline { points, closed }, true) = &geometry[0] else {
            panic!("{geometry:?}")
        };
        assert!(*closed && points[0] == Point2::new(0.0, 0.0));
        // Arrow length 2 along the first segment's direction.
        let base_x = (points[1].x + points[2].x) / 2.0;
        assert!((base_x - 2.0 / 2f64.sqrt()).abs() < 1e-12);
        let (Entity2DGeometry::Polyline { points, .. }, false) = &geometry[1] else {
            panic!()
        };
        assert_eq!(points.last(), Some(&Point2::new(12.0, 10.0)));
        let (Entity2DGeometry::Line { start, end }, false) = &geometry[2] else {
            panic!()
        };
        assert_eq!(
            (*start, *end),
            (Point2::new(12.0, 10.0), Point2::new(15.0, 10.0))
        );
    }

    #[test]
    fn invisible_leaders_hide_lines_arrows_and_landing() {
        let model = MLeaderModel {
            branches: vec![LeaderBranch {
                lines: vec![LeaderLine {
                    points: vec![[0.0, 0.0, 0.0]],
                }],
                last_point: Some([1.0, 0.0, 0.0]),
                dogleg: [1.0, 0.0, 0.0],
                dogleg_length: 2.0,
            }],
            path: LeaderPath::Invisible,
            line_color: CmColor::ByLayer,
            dogleg_enabled: true,
            arrowhead_size: 1.0,
            arrowhead_handle: None,
            text: None,
            block: None,
        };
        assert!(leader_geometry(&model, Arrowhead::ClosedFilled).is_empty());
    }

    #[test]
    fn table_rotation_reads_the_direction_in_the_ocs() {
        let up = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];
        assert!((table_rotation([0.0, 1.0, 0.0], up) - std::f64::consts::FRAC_PI_2).abs() < 1e-12);
        let down = [[-1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, -1.0]];
        assert!((table_rotation([1.0, 0.0, 0.0], down) - std::f64::consts::PI).abs() < 1e-12);
    }
}
