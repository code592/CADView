use crate::text_coordinates::{ocs_axes, Axes3};
use cad_core::{Entity2DGeometry, Point2};
use std::f64::consts::{PI, TAU};

const IDENTITY_AXES: Axes3 = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];

/// OCS axes for an entity normal. A missing or degenerate normal is treated as
/// the default +Z extrusion rather than discarding the entity.
pub(crate) fn ocs_axes_or_world(normal: [f64; 3]) -> Axes3 {
    ocs_axes(normal).unwrap_or(IDENTITY_AXES)
}

/// Projects an OCS point (including its elevation) onto the world XY plane.
pub(crate) fn ocs_world_point(axes: Axes3, point: [f64; 3]) -> [f64; 3] {
    [0, 1, 2].map(|row| axes[0][row] * point[0] + axes[1][row] * point[1] + axes[2][row] * point[2])
}

/// Normalizes a CIRCLE or ARC whose center is already in world coordinates
/// and whose angles are measured counter-clockwise in the OCS of [normal].
///
/// A +Z normal keeps the angles. A -Z normal (the usual result of mirroring in
/// CAD) mirrors the OCS X axis, so each angle is mapped through the plane and
/// start/end are swapped to keep the stored arc counter-clockwise in world XY.
/// A tilted plane projects to an ellipse, which is emitted as a polyline.
pub(crate) fn ocs_circle_or_arc(
    center: [f64; 3],
    radius: f64,
    normal: [f64; 3],
    angles: Option<(f64, f64)>,
) -> Entity2DGeometry {
    let axes = ocs_axes_or_world(normal);
    let radius = radius.abs();
    let world_center = Point2::new(center[0], center[1]);
    let planar = axes[2][0].abs() <= 1e-12 && axes[2][1].abs() <= 1e-12;
    if planar {
        let Some((start, end)) = angles else {
            return Entity2DGeometry::Circle {
                center: world_center,
                radius,
            };
        };
        if axes[2][2] > 0.0 {
            return Entity2DGeometry::Arc {
                center: world_center,
                radius,
                start_angle: start,
                end_angle: end,
            };
        }
        let world_angle = |angle: f64| {
            let (sin, cos) = angle.sin_cos();
            (axes[0][1] * cos + axes[1][1] * sin).atan2(axes[0][0] * cos + axes[1][0] * sin)
        };
        // Keep an exact full circle (start == end) full after the mapping.
        let (start_angle, end_angle) = if start == end {
            let mapped = world_angle(start);
            (mapped, mapped)
        } else {
            (world_angle(end), world_angle(start))
        };
        return Entity2DGeometry::Arc {
            center: world_center,
            radius,
            start_angle,
            end_angle,
        };
    }

    let (start, sweep, closed) = match angles {
        None => (0.0, TAU, true),
        Some((start, end)) => {
            let sweep = (end - start).rem_euclid(TAU);
            if sweep <= 1e-12 {
                (start, TAU, true)
            } else {
                (start, sweep, false)
            }
        }
    };
    // At most five degrees per chord, matching the bulge tessellation density.
    let steps = (sweep / (PI / 36.0)).ceil().clamp(2.0, 72.0) as usize;
    let count = if closed { steps } else { steps + 1 };
    let points = (0..count)
        .map(|index| {
            let (sin, cos) = (start + sweep * index as f64 / steps as f64).sin_cos();
            Point2::new(
                center[0] + radius * (axes[0][0] * cos + axes[1][0] * sin),
                center[1] + radius * (axes[0][1] * cos + axes[1][1] * sin),
            )
        })
        .collect();
    Entity2DGeometry::Polyline { points, closed }
}

/// Normalizes a CIRCLE or ARC exactly as stored in DXF/DWG: center, angles
/// and elevation are all in the OCS of [normal].
pub(crate) fn ocs_entity_circle_or_arc(
    center: [f64; 3],
    radius: f64,
    normal: [f64; 3],
    angles: Option<(f64, f64)>,
) -> Entity2DGeometry {
    let world_center = ocs_world_point(ocs_axes_or_world(normal), center);
    ocs_circle_or_arc(world_center, radius, normal, angles)
}

/// Converts a CAD bulge polyline into a smooth display polyline. A bulge is
/// tan(included_angle / 4); ignoring it turns every rounded profile into
/// straight chords. Vertices are OCS coordinates; [project] maps them to world.
pub(crate) fn tessellate_bulged_polyline(
    vertices: &[(f64, f64, f64)],
    closed: bool,
    project: impl Fn(f64, f64) -> Point2,
) -> Vec<Point2> {
    if vertices.is_empty() {
        return Vec::new();
    }
    if vertices.len() == 1 {
        return vec![project(vertices[0].0, vertices[0].1)];
    }

    let segment_count = if closed {
        vertices.len()
    } else {
        vertices.len() - 1
    };
    let mut points = vec![project(vertices[0].0, vertices[0].1)];
    for index in 0..segment_count {
        let (x1, y1, bulge) = vertices[index];
        let (x2, y2, _) = vertices[(index + 1) % vertices.len()];
        let dx = x2 - x1;
        let dy = y2 - y1;
        let chord = dx.hypot(dy);
        if chord < 1e-12 || bulge.abs() < 1e-10 || !bulge.is_finite() {
            points.push(project(x2, y2));
            continue;
        }

        let midpoint_x = (x1 + x2) * 0.5;
        let midpoint_y = (y1 + y2) * 0.5;
        let center_offset = chord * (1.0 - bulge * bulge) / (4.0 * bulge);
        let center_x = midpoint_x - dy / chord * center_offset;
        let center_y = midpoint_y + dx / chord * center_offset;
        let start_angle = (y1 - center_y).atan2(x1 - center_x);
        let sweep = 4.0 * bulge.atan();
        // At most ten degrees per chord is sufficiently smooth for mobile
        // display while keeping pathological drawings bounded.
        let steps = (sweep.abs() / (PI / 18.0)).ceil().clamp(2.0, 72.0) as usize;
        let radius = chord * (1.0 + bulge * bulge) / (4.0 * bulge.abs());
        for step in 1..steps {
            let angle = start_angle + sweep * step as f64 / steps as f64;
            points.push(project(
                center_x + radius * angle.cos(),
                center_y + radius * angle.sin(),
            ));
        }
        // End exactly on the next vertex instead of a recomputed point.
        points.push(project(x2, y2));
    }
    points
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arc_point(geometry: &Entity2DGeometry, use_end: bool) -> (f64, f64) {
        let Entity2DGeometry::Arc {
            center,
            radius,
            start_angle,
            end_angle,
        } = geometry
        else {
            panic!("expected an arc, got {geometry:?}");
        };
        let angle = if use_end { *end_angle } else { *start_angle };
        (
            center.x + radius * angle.cos(),
            center.y + radius * angle.sin(),
        )
    }

    fn close(a: (f64, f64), b: (f64, f64)) -> bool {
        (a.0 - b.0).abs() < 1e-9 && (a.1 - b.1).abs() < 1e-9
    }

    #[test]
    fn up_normal_keeps_arc_angles() {
        let geometry = ocs_circle_or_arc([5.0, 6.0, 0.0], 2.0, [0.0, 0.0, 1.0], Some((0.1, 1.2)));
        assert!(matches!(
            geometry,
            Entity2DGeometry::Arc {
                center: Point2 { x: 5.0, y: 6.0 },
                radius: 2.0,
                start_angle: 0.1,
                end_angle: 1.2,
            }
        ));
    }

    #[test]
    fn down_normal_mirrors_and_swaps_arc_endpoints() {
        // OCS for (0,0,-1): X axis is world -X and Y axis is world +Y. The
        // center is supplied in world coordinates (OCS (3, 4) → world (-3, 4)).
        let geometry = ocs_circle_or_arc(
            [-3.0, 4.0, 0.0],
            2.0,
            [0.0, 0.0, -1.0],
            Some((0.0, PI / 2.0)),
        );
        // OCS start (r, 0) maps to world (-r, 0); OCS end (0, r) to (0, r).
        // The world arc is counter-clockwise from the OCS end to the OCS start.
        assert!(close(arc_point(&geometry, false), (-3.0, 6.0)));
        assert!(close(arc_point(&geometry, true), (-5.0, 4.0)));
        let Entity2DGeometry::Arc {
            start_angle,
            end_angle,
            ..
        } = geometry
        else {
            unreachable!()
        };
        let sweep = (end_angle - start_angle).rem_euclid(TAU);
        assert!((sweep - PI / 2.0).abs() < 1e-12);
    }

    #[test]
    fn down_normal_full_circle_stays_full() {
        let geometry = ocs_circle_or_arc([0.0, 0.0, 0.0], 1.0, [0.0, 0.0, -1.0], Some((0.7, 0.7)));
        let Entity2DGeometry::Arc {
            start_angle,
            end_angle,
            ..
        } = geometry
        else {
            panic!("expected arc")
        };
        assert_eq!(start_angle, end_angle);
    }

    #[test]
    fn down_normal_circle_keeps_world_center() {
        assert!(matches!(
            ocs_circle_or_arc([-3.0, 4.0, 0.0], 2.0, [0.0, 0.0, -1.0], None),
            Entity2DGeometry::Circle {
                center: Point2 { x: -3.0, y: 4.0 },
                radius: 2.0,
            }
        ));
    }

    #[test]
    fn tilted_circle_projects_to_an_ellipse_outline() {
        // Normal in the XZ plane at 60 degrees from +Z: the projected minor
        // radius along world X is r * cos(60 degrees).
        let normal = [(PI / 3.0).sin(), 0.0, (PI / 3.0).cos()];
        let Entity2DGeometry::Polyline { points, closed } =
            ocs_circle_or_arc([10.0, 20.0, 0.0], 4.0, normal, None)
        else {
            panic!("expected polyline");
        };
        assert!(closed);
        let max_x = points.iter().map(|p| p.x - 10.0).fold(f64::MIN, f64::max);
        let max_y = points.iter().map(|p| p.y - 20.0).fold(f64::MIN, f64::max);
        assert!((max_x - 2.0).abs() < 1e-9, "{max_x}");
        assert!((max_y - 4.0).abs() < 0.02, "{max_y}");
    }

    #[test]
    fn ocs_point_mirrors_x_for_down_normal() {
        let axes = ocs_axes_or_world([0.0, 0.0, -1.0]);
        let p = ocs_world_point(axes, [3.0, 4.0, 5.0]);
        assert!((p[0] + 3.0).abs() < 1e-12 && (p[1] - 4.0).abs() < 1e-12);
        assert!((p[2] + 5.0).abs() < 1e-12);
    }

    #[test]
    fn bulge_one_is_a_semicircle_through_exact_endpoints() {
        let points =
            tessellate_bulged_polyline(&[(0.0, 0.0, 1.0), (2.0, 0.0, 0.0)], false, Point2::new);
        assert_eq!(points.first(), Some(&Point2::new(0.0, 0.0)));
        assert_eq!(points.last(), Some(&Point2::new(2.0, 0.0)));
        // Positive bulge turns counter-clockwise: the arc lies below the chord.
        for point in &points {
            assert!(((point.x - 1.0).hypot(point.y) - 1.0).abs() < 1e-12);
            assert!(point.y <= 1e-12);
        }
        assert!(points.iter().any(|point| (point.y + 1.0).abs() < 1e-12));
    }
}
