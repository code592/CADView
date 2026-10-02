use crate::{Point2, Point3};
use rstar::{RTree, RTreeObject, AABB};
use std::collections::{HashMap, HashSet};

pub fn distance_2d(a: Point2, b: Point2) -> f64 {
    (b.x - a.x).hypot(b.y - a.y)
}

pub fn distance_3d(a: Point3, b: Point3) -> f64 {
    ((b.x - a.x).powi(2) + (b.y - a.y).powi(2) + (b.z - a.z).powi(2)).sqrt()
}

/// Returns the exact triangulated surface area for a valid indexed mesh.
/// Invalid indices, incomplete triangles and non-finite geometry reject the
/// entire result so callers never present a plausible partial area.
pub fn mesh_surface_area(positions: &[Point3], indices: &[u32]) -> Option<f64> {
    if positions.is_empty() || indices.is_empty() || indices.len() % 3 != 0 {
        return None;
    }
    let mut total = 0.0;
    let mut compensation = 0.0;
    for triangle in indices.chunks_exact(3) {
        let first = *positions.get(triangle[0] as usize)?;
        let second = *positions.get(triangle[1] as usize)?;
        let third = *positions.get(triangle[2] as usize)?;
        if !finite_point3(first) || !finite_point3(second) || !finite_point3(third) {
            return None;
        }
        let first_edge = Point3::new(second.x - first.x, second.y - first.y, second.z - first.z);
        let second_edge = Point3::new(third.x - first.x, third.y - first.y, third.z - first.z);
        let first_length = stable_length3(first_edge)?;
        let second_length = stable_length3(second_edge)?;
        let triangle_area = if first_length == 0.0 || second_length == 0.0 {
            0.0
        } else {
            let first_unit = Point3::new(
                first_edge.x / first_length,
                first_edge.y / first_length,
                first_edge.z / first_length,
            );
            let second_unit = Point3::new(
                second_edge.x / second_length,
                second_edge.y / second_length,
                second_edge.z / second_length,
            );
            let cross_x = first_unit.y * second_unit.z - first_unit.z * second_unit.y;
            let cross_y = first_unit.z * second_unit.x - first_unit.x * second_unit.z;
            let cross_z = first_unit.x * second_unit.y - first_unit.y * second_unit.x;
            let sine = stable_length3(Point3::new(cross_x, cross_y, cross_z))?;
            let larger = first_length.max(second_length);
            let smaller = first_length.min(second_length);
            (larger * (sine * 0.5)) * smaller
        };
        if !triangle_area.is_finite() || triangle_area < 0.0 {
            return None;
        }
        let corrected = triangle_area - compensation;
        let updated = total + corrected;
        if !updated.is_finite() {
            return None;
        }
        compensation = (updated - total) - corrected;
        total = updated;
    }
    Some(total)
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MeshVolumeProperties {
    /// True only when every welded, undirected edge belongs to exactly two
    /// oppositely directed triangles.
    pub closed_manifold: bool,
    /// A finite volume is exposed only for one connected, consistently wound
    /// closed shell. Multi-shell meshes are deliberately left unmeasured
    /// because distinguishing separate solids from nested cavities requires
    /// additional solid topology.
    pub enclosed_volume: Option<f64>,
    /// Centroid of the enclosed volume. With uniform material density this is
    /// also the center of mass. It follows the same single-shell validity gate
    /// as [Self::enclosed_volume].
    pub volume_centroid: Option<Point3>,
}

/// Validates triangle topology and computes an origin-relocated signed
/// tetrahedral volume for a single closed shell.
///
/// Vertices with bit-identical coordinates are welded for topology checks so
/// OBJ/glTF attribute seams and indexed STL data do not appear falsely open.
/// Invalid indices, non-finite coordinates, degenerate triangles,
/// non-manifold edges and inconsistent winding never produce a volume.
pub fn mesh_volume_properties(
    positions: &[Point3],
    indices: &[u32],
) -> Option<MeshVolumeProperties> {
    if positions.is_empty() || indices.is_empty() || indices.len() % 3 != 0 {
        return None;
    }

    let mut vertex_ids = HashMap::<[u64; 3], usize>::new();
    let mut disjoint = DisjointSet::new(0);
    let mut edges = HashMap::<(usize, usize), (u32, i32)>::new();
    let mut origin = None;
    let mut signed_six_volume = 0.0;
    let mut compensation = 0.0;
    let mut centroid_numerator = [0.0_f64; 3];
    let mut centroid_compensation = [0.0_f64; 3];
    let mut centroid_finite = true;

    for triangle in indices.chunks_exact(3) {
        let mut triangle_ids = [0_usize; 3];
        let mut triangle_points = [Point3::new(0.0, 0.0, 0.0); 3];
        for corner in 0..3 {
            let point = *positions.get(triangle[corner] as usize)?;
            if !finite_point3(point) {
                return None;
            }
            let key = [
                coordinate_bits(point.x),
                coordinate_bits(point.y),
                coordinate_bits(point.z),
            ];
            let id = match vertex_ids.get(&key) {
                Some(id) => *id,
                None => {
                    let id = vertex_ids.len();
                    vertex_ids.insert(key, id);
                    disjoint.add();
                    id
                }
            };
            triangle_ids[corner] = id;
            triangle_points[corner] = point;
        }
        let [first_id, second_id, third_id] = triangle_ids;
        if first_id == second_id || second_id == third_id || third_id == first_id {
            return None;
        }
        let [first, second, third] = triangle_points;
        let first_edge = Point3::new(second.x - first.x, second.y - first.y, second.z - first.z);
        let second_edge = Point3::new(third.x - first.x, third.y - first.y, third.z - first.z);
        let normal = cross3(first_edge, second_edge);
        if stable_length3(normal)? == 0.0 {
            return None;
        }

        disjoint.union(first_id, second_id);
        disjoint.union(second_id, third_id);
        for (start, end) in [
            (first_id, second_id),
            (second_id, third_id),
            (third_id, first_id),
        ] {
            let (key, direction) = if start < end {
                ((start, end), 1)
            } else {
                ((end, start), -1)
            };
            let entry = edges.entry(key).or_insert((0, 0));
            entry.0 = entry.0.saturating_add(1);
            entry.1 += direction;
        }

        let origin = *origin.get_or_insert(first);
        let a = Point3::new(first.x - origin.x, first.y - origin.y, first.z - origin.z);
        let b = Point3::new(
            second.x - origin.x,
            second.y - origin.y,
            second.z - origin.z,
        );
        let c = Point3::new(third.x - origin.x, third.y - origin.y, third.z - origin.z);
        let term = dot3(a, cross3(b, c));
        if !term.is_finite() {
            return None;
        }
        let corrected = term - compensation;
        let updated = signed_six_volume + corrected;
        if !updated.is_finite() {
            return None;
        }
        compensation = (updated - signed_six_volume) - corrected;
        signed_six_volume = updated;

        for (axis, coordinate_sum) in [a.x + b.x + c.x, a.y + b.y + c.y, a.z + b.z + c.z]
            .into_iter()
            .enumerate()
        {
            let weighted = term * coordinate_sum;
            if !weighted.is_finite() {
                centroid_finite = false;
                continue;
            }
            let corrected = weighted - centroid_compensation[axis];
            let updated = centroid_numerator[axis] + corrected;
            if !updated.is_finite() {
                centroid_finite = false;
                continue;
            }
            centroid_compensation[axis] = (updated - centroid_numerator[axis]) - corrected;
            centroid_numerator[axis] = updated;
        }
    }

    let closed_manifold = edges
        .values()
        .all(|(incidence, direction_balance)| *incidence == 2 && *direction_balance == 0);
    if !closed_manifold {
        return Some(MeshVolumeProperties {
            closed_manifold: false,
            enclosed_volume: None,
            volume_centroid: None,
        });
    }

    let shell_count = (0..vertex_ids.len())
        .map(|vertex| disjoint.find(vertex))
        .collect::<HashSet<_>>()
        .len();
    let single_shell = shell_count == 1;
    let volume = (signed_six_volume.abs() / 6.0)
        .is_finite()
        .then_some(signed_six_volume.abs() / 6.0)
        .filter(|value| single_shell && *value > 0.0);
    let volume_centroid = if volume.is_some() && centroid_finite {
        let origin = origin?;
        let denominator = signed_six_volume * 4.0;
        let centroid = Point3::new(
            origin.x + centroid_numerator[0] / denominator,
            origin.y + centroid_numerator[1] / denominator,
            origin.z + centroid_numerator[2] / denominator,
        );
        finite_point3(centroid).then_some(centroid)
    } else {
        None
    };
    Some(MeshVolumeProperties {
        closed_manifold: true,
        enclosed_volume: volume,
        volume_centroid,
    })
}

fn coordinate_bits(value: f64) -> u64 {
    if value == 0.0 {
        0
    } else {
        value.to_bits()
    }
}

fn cross3(first: Point3, second: Point3) -> Point3 {
    Point3::new(
        first.y * second.z - first.z * second.y,
        first.z * second.x - first.x * second.z,
        first.x * second.y - first.y * second.x,
    )
}

fn dot3(first: Point3, second: Point3) -> f64 {
    first.x * second.x + first.y * second.y + first.z * second.z
}

struct DisjointSet {
    parents: Vec<usize>,
    ranks: Vec<u8>,
}

impl DisjointSet {
    fn new(length: usize) -> Self {
        Self {
            parents: (0..length).collect(),
            ranks: vec![0; length],
        }
    }

    fn add(&mut self) {
        self.parents.push(self.parents.len());
        self.ranks.push(0);
    }

    fn find(&mut self, value: usize) -> usize {
        if self.parents[value] != value {
            self.parents[value] = self.find(self.parents[value]);
        }
        self.parents[value]
    }

    fn union(&mut self, first: usize, second: usize) {
        let first_root = self.find(first);
        let second_root = self.find(second);
        if first_root == second_root {
            return;
        }
        if self.ranks[first_root] < self.ranks[second_root] {
            self.parents[first_root] = second_root;
        } else {
            self.parents[second_root] = first_root;
            if self.ranks[first_root] == self.ranks[second_root] {
                self.ranks[first_root] = self.ranks[first_root].saturating_add(1);
            }
        }
    }
}

fn stable_length3(vector: Point3) -> Option<f64> {
    if !finite_point3(vector) {
        return None;
    }
    let scale = vector.x.abs().max(vector.y.abs()).max(vector.z.abs());
    if scale == 0.0 {
        return Some(0.0);
    }
    let x = vector.x / scale;
    let y = vector.y / scale;
    let z = vector.z / scale;
    let value = scale * (x * x + y * y + z * z).sqrt();
    value.is_finite().then_some(value)
}

fn finite_point3(point: Point3) -> bool {
    point.x.is_finite() && point.y.is_finite() && point.z.is_finite()
}

pub fn angle_2d(vertex: Point2, first: Point2, second: Point2) -> f64 {
    let a = (first.y - vertex.y).atan2(first.x - vertex.x);
    let b = (second.y - vertex.y).atan2(second.x - vertex.x);
    (b - a).rem_euclid(std::f64::consts::TAU)
}

pub fn polygon_area(points: &[Point2]) -> f64 {
    if points.len() < 3 {
        return 0.0;
    }
    points
        .iter()
        .zip(points.iter().cycle().skip(1))
        .take(points.len())
        .map(|(a, b)| a.x * b.y - b.x * a.y)
        .sum::<f64>()
        .abs()
        * 0.5
}

/// Computes an area only for a finite, non-degenerate simple polygon.
///
/// The R-tree limits intersection checks to segments whose envelopes overlap,
/// avoiding an unconditional quadratic scan for ordinary CAD boundaries.
pub fn simple_polygon_area(source: &[Point2], max_validation_vertices: usize) -> Option<f64> {
    if source.len() < 3 || source.iter().any(|point| !finite_point(*point)) {
        return None;
    }
    let mut points = source.to_vec();
    let tolerance = polygon_tolerance(&points);
    if same_point(*points.first()?, *points.last()?, tolerance) {
        points.pop();
    }
    if points.len() < 3 || points.len() > max_validation_vertices {
        return None;
    }

    let segments = (0..points.len())
        .map(|index| PolygonSegment {
            index,
            start: points[index],
            end: points[(index + 1) % points.len()],
            tolerance,
        })
        .collect::<Vec<_>>();
    if segments
        .iter()
        .any(|segment| same_point(segment.start, segment.end, tolerance))
    {
        return None;
    }

    let tree = RTree::bulk_load(segments.clone());
    for segment in &segments {
        for candidate in tree.locate_in_envelope_intersecting(&segment.envelope()) {
            if candidate.index <= segment.index {
                continue;
            }
            let adjacent = candidate.index == segment.index + 1
                || (segment.index == 0 && candidate.index == segments.len() - 1);
            if !adjacent
                && segments_intersect(
                    segment.start,
                    segment.end,
                    candidate.start,
                    candidate.end,
                    tolerance,
                )
            {
                return None;
            }
        }
    }

    let origin = points[0];
    let mut twice_area = 0.0;
    let mut compensation = 0.0;
    for index in 0..points.len() {
        let current = Point2::new(points[index].x - origin.x, points[index].y - origin.y);
        let next_point = points[(index + 1) % points.len()];
        let next = Point2::new(next_point.x - origin.x, next_point.y - origin.y);
        let term = current.x * next.y - next.x * current.y;
        let corrected = term - compensation;
        let updated = twice_area + corrected;
        compensation = (updated - twice_area) - corrected;
        twice_area = updated;
    }
    let area = twice_area.abs() * 0.5;
    (area.is_finite() && area > tolerance * tolerance).then_some(area)
}

#[derive(Debug, Clone, Copy)]
struct PolygonSegment {
    index: usize,
    start: Point2,
    end: Point2,
    tolerance: f64,
}

impl RTreeObject for PolygonSegment {
    type Envelope = AABB<[f64; 2]>;

    fn envelope(&self) -> Self::Envelope {
        AABB::from_corners(
            [
                self.start.x.min(self.end.x) - self.tolerance,
                self.start.y.min(self.end.y) - self.tolerance,
            ],
            [
                self.start.x.max(self.end.x) + self.tolerance,
                self.start.y.max(self.end.y) + self.tolerance,
            ],
        )
    }
}

fn polygon_tolerance(points: &[Point2]) -> f64 {
    let (mut min_x, mut max_x) = (points[0].x, points[0].x);
    let (mut min_y, mut max_y) = (points[0].y, points[0].y);
    for point in &points[1..] {
        min_x = min_x.min(point.x);
        max_x = max_x.max(point.x);
        min_y = min_y.min(point.y);
        max_y = max_y.max(point.y);
    }
    (max_x - min_x).max(max_y - min_y).max(1.0) * 1e-12
}

fn finite_point(point: Point2) -> bool {
    point.x.is_finite() && point.y.is_finite()
}

fn same_point(first: Point2, second: Point2, tolerance: f64) -> bool {
    distance_2d(first, second) <= tolerance
}

fn segments_intersect(a: Point2, b: Point2, c: Point2, d: Point2, tolerance: f64) -> bool {
    let first = orientation(a, b, c, tolerance);
    let second = orientation(a, b, d, tolerance);
    let third = orientation(c, d, a, tolerance);
    let fourth = orientation(c, d, b, tolerance);
    if first * second < 0 && third * fourth < 0 {
        return true;
    }
    (first == 0 && on_segment(a, b, c, tolerance))
        || (second == 0 && on_segment(a, b, d, tolerance))
        || (third == 0 && on_segment(c, d, a, tolerance))
        || (fourth == 0 && on_segment(c, d, b, tolerance))
}

fn orientation(a: Point2, b: Point2, c: Point2, tolerance: f64) -> i32 {
    let ab = Point2::new(b.x - a.x, b.y - a.y);
    let ac = Point2::new(c.x - a.x, c.y - a.y);
    let cross = ab.x * ac.y - ab.y * ac.x;
    let epsilon = tolerance * distance_2d(a, b).max(distance_2d(a, c)).max(1.0);
    if cross.abs() <= epsilon {
        0
    } else if cross > 0.0 {
        1
    } else {
        -1
    }
}

fn on_segment(start: Point2, end: Point2, point: Point2, tolerance: f64) -> bool {
    point.x >= start.x.min(end.x) - tolerance
        && point.x <= start.x.max(end.x) + tolerance
        && point.y >= start.y.min(end.y) - tolerance
        && point.y <= start.y.max(end.y) + tolerance
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn measures_distance_and_area() {
        assert_eq!(
            distance_2d(Point2::new(0.0, 0.0), Point2::new(3.0, 4.0)),
            5.0
        );
        assert_eq!(
            polygon_area(&[
                Point2::new(0.0, 0.0),
                Point2::new(4.0, 0.0),
                Point2::new(4.0, 3.0),
                Point2::new(0.0, 3.0),
            ]),
            12.0
        );
        assert_eq!(
            simple_polygon_area(
                &[
                    Point2::new(1.0e12, 1.0e12),
                    Point2::new(1.0e12 + 6.0, 1.0e12),
                    Point2::new(1.0e12 + 6.0, 1.0e12 + 4.0),
                    Point2::new(1.0e12, 1.0e12 + 4.0),
                ],
                4096,
            ),
            Some(24.0)
        );
        assert_eq!(
            simple_polygon_area(
                &[
                    Point2::new(0.0, 0.0),
                    Point2::new(4.0, 4.0),
                    Point2::new(0.0, 4.0),
                    Point2::new(4.0, 0.0),
                ],
                4096,
            ),
            None
        );
        assert_eq!(
            simple_polygon_area(
                &[
                    Point2::new(0.0, 0.0),
                    Point2::new(2.0, 0.0),
                    Point2::new(4.0, 0.0),
                ],
                4096,
            ),
            None
        );
    }

    #[test]
    fn mesh_area_is_stable_and_rejects_partial_geometry() {
        let positions = [
            Point3::new(1.0e12, -1.0e12, 5.0),
            Point3::new(1.0e12 + 3.0, -1.0e12, 5.0),
            Point3::new(1.0e12, -1.0e12 + 4.0, 5.0),
            Point3::new(1.0e12, -1.0e12, 5.0),
        ];
        assert_eq!(mesh_surface_area(&positions, &[0, 1, 2]), Some(6.0));
        assert_eq!(
            mesh_surface_area(&positions, &[0, 1, 2, 0, 0, 3]),
            Some(6.0)
        );
        assert_eq!(mesh_surface_area(&positions, &[0, 1]), None);
        assert_eq!(mesh_surface_area(&positions, &[0, 1, 9]), None);
        assert_eq!(mesh_surface_area(&positions, &[]), None);

        let invalid = [
            Point3::new(0.0, 0.0, 0.0),
            Point3::new(f64::INFINITY, 0.0, 0.0),
            Point3::new(0.0, 1.0, 0.0),
        ];
        assert_eq!(mesh_surface_area(&invalid, &[0, 1, 2]), None);
    }

    #[test]
    fn mesh_volume_requires_one_consistently_wound_closed_shell() {
        let tetrahedron = [
            Point3::new(1.0e12, -1.0e12, 5.0),
            Point3::new(1.0e12 + 1.0, -1.0e12, 5.0),
            Point3::new(1.0e12, -1.0e12 + 1.0, 5.0),
            Point3::new(1.0e12, -1.0e12, 6.0),
        ];
        let closed = [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3];
        let properties = mesh_volume_properties(&tetrahedron, &closed).unwrap();
        assert!(properties.closed_manifold);
        assert_eq!(properties.enclosed_volume, Some(1.0 / 6.0));
        assert_eq!(
            properties.volume_centroid,
            Some(Point3::new(1.0e12 + 0.25, -1.0e12 + 0.25, 5.25))
        );

        let open = mesh_volume_properties(&tetrahedron, &closed[..9]).unwrap();
        assert!(!open.closed_manifold);
        assert_eq!(open.enclosed_volume, None);
        assert_eq!(open.volume_centroid, None);

        let inconsistent = [0, 1, 2, 0, 1, 3, 0, 3, 2, 1, 2, 3];
        let inconsistent = mesh_volume_properties(&tetrahedron, &inconsistent).unwrap();
        assert!(!inconsistent.closed_manifold);
        assert_eq!(inconsistent.enclosed_volume, None);
        assert_eq!(inconsistent.volume_centroid, None);

        let duplicated_positions = closed
            .iter()
            .map(|index| tetrahedron[*index as usize])
            .collect::<Vec<_>>();
        let duplicated_indices = (0..duplicated_positions.len() as u32).collect::<Vec<_>>();
        let welded = mesh_volume_properties(&duplicated_positions, &duplicated_indices).unwrap();
        assert!(welded.closed_manifold);
        assert_eq!(welded.enclosed_volume, Some(1.0 / 6.0));
        assert_eq!(welded.volume_centroid, properties.volume_centroid);

        let mut two_shells = tetrahedron.to_vec();
        two_shells.extend(
            tetrahedron
                .iter()
                .map(|point| Point3::new(point.x + 10.0, point.y, point.z)),
        );
        let mut two_shell_indices = closed.to_vec();
        two_shell_indices.extend(closed.iter().map(|index| index + 4));
        let two_shells = mesh_volume_properties(&two_shells, &two_shell_indices).unwrap();
        assert!(two_shells.closed_manifold);
        assert_eq!(two_shells.enclosed_volume, None);
        assert_eq!(two_shells.volume_centroid, None);

        assert_eq!(mesh_volume_properties(&tetrahedron, &[0, 1, 9]), None);
        assert_eq!(mesh_volume_properties(&tetrahedron, &[0, 1]), None);
    }
}
