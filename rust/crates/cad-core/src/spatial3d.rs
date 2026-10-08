//! Runtime triangle acceleration; never serialized or approximated geometry.
use crate::{Bounds3, Point3, Scene3D};
use rstar::{RTree, RTreeObject, SelectionFunction, AABB};

#[derive(Debug, Clone, Copy)]
struct TriangleEntry {
    mesh_index: usize,
    triangle_index: usize,
    envelope: AABB<[f64; 3]>,
}
impl RTreeObject for TriangleEntry {
    type Envelope = AABB<[f64; 3]>;
    fn envelope(&self) -> Self::Envelope {
        self.envelope
    }
}

#[derive(Debug, Default)]
pub struct SceneIndex3D {
    tree: RTree<TriangleEntry>,
}

impl SceneIndex3D {
    pub fn build(scene: &Scene3D) -> Self {
        let mut entries = Vec::with_capacity(scene.stats.triangle_count as usize);
        for (mesh_index, mesh) in scene.meshes.iter().enumerate() {
            for (triangle_index, triangle) in mesh.indices.chunks_exact(3).enumerate() {
                let Some(a) = mesh.positions.get(triangle[0] as usize) else {
                    continue;
                };
                let Some(b) = mesh.positions.get(triangle[1] as usize) else {
                    continue;
                };
                let Some(c) = mesh.positions.get(triangle[2] as usize) else {
                    continue;
                };
                let bounds = Bounds3::from_points([*a, *b, *c]).unwrap();
                if ![a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z]
                    .into_iter()
                    .all(f64::is_finite)
                {
                    continue;
                }
                entries.push(TriangleEntry {
                    mesh_index,
                    triangle_index,
                    envelope: AABB::from_corners(
                        [bounds.min.x, bounds.min.y, bounds.min.z],
                        [bounds.max.x, bounds.max.y, bounds.max.z],
                    ),
                });
            }
        }
        Self {
            tree: RTree::bulk_load(entries),
        }
    }

    pub fn ray_candidates(&self, origin: Point3, direction: Point3) -> Vec<(usize, usize)> {
        let selection = RaySelection {
            origin: [origin.x, origin.y, origin.z],
            direction: [direction.x, direction.y, direction.z],
        };
        let mut candidates = self
            .tree
            .locate_with_selection_function(selection)
            .map(|entry| (entry.mesh_index, entry.triangle_index))
            .collect::<Vec<_>>();
        candidates.sort_unstable();
        candidates
    }
}

struct RaySelection {
    origin: [f64; 3],
    direction: [f64; 3],
}
impl RaySelection {
    fn intersects(&self, envelope: &AABB<[f64; 3]>) -> bool {
        let lower = envelope.lower();
        let upper = envelope.upper();
        let mut near = 0.0_f64;
        let mut far = f64::INFINITY;
        for axis in 0..3 {
            // Conservative round-off guard for exact boundary/parallel hits.
            let tolerance = lower[axis].abs().max(upper[axis].abs()).max(1.0) * 4.0 * f64::EPSILON;
            let lo = lower[axis] - tolerance;
            let hi = upper[axis] + tolerance;
            if self.direction[axis] == 0.0 {
                if self.origin[axis] < lo || self.origin[axis] > hi {
                    return false;
                }
            } else {
                let a = (lo - self.origin[axis]) / self.direction[axis];
                let b = (hi - self.origin[axis]) / self.direction[axis];
                near = near.max(a.min(b));
                far = far.min(a.max(b));
                if near > far {
                    return false;
                }
            }
        }
        true
    }
}
impl SelectionFunction<TriangleEntry> for RaySelection {
    fn should_unpack_parent(&self, envelope: &AABB<[f64; 3]>) -> bool {
        self.intersects(envelope)
    }
    fn should_unpack_leaf(&self, leaf: &TriangleEntry) -> bool {
        self.intersects(&leaf.envelope)
    }
}

/// Double-sided exact triangle intersection; geometry is untouched by indexing.
pub fn ray_triangle_distance(
    origin: Point3,
    direction: Point3,
    a: Point3,
    b: Point3,
    c: Point3,
) -> Option<f64> {
    fn sub(a: Point3, b: Point3) -> Point3 {
        Point3::new(a.x - b.x, a.y - b.y, a.z - b.z)
    }
    fn dot(a: Point3, b: Point3) -> f64 {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
    fn cross(a: Point3, b: Point3) -> Point3 {
        Point3::new(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x,
        )
    }
    let e1 = sub(b, a);
    let e2 = sub(c, a);
    let h = cross(direction, e2);
    let det = dot(e1, h);
    if det.abs() < 1e-9 {
        return None;
    }
    let inv = 1.0 / det;
    let s = sub(origin, a);
    let u = inv * dot(s, h);
    if !(0.0..=1.0).contains(&u) {
        return None;
    }
    let q = cross(s, e1);
    let v = inv * dot(direction, q);
    if v < 0.0 || u + v > 1.0 {
        return None;
    }
    let distance = inv * dot(e2, q);
    (distance > 1e-9 && distance.is_finite()).then_some(distance)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ray_box_keeps_parallel_boundaries_and_rejects_behind_origin() {
        let bounds = AABB::from_corners([1.0, 2.0, 3.0], [4.0, 5.0, 3.0]);
        let ray = RaySelection {
            origin: [1.0, 2.0, 10.0],
            direction: [0.0, 0.0, -1.0],
        };
        assert!(ray.intersects(&bounds));
        assert!(!RaySelection {
            direction: [0.0, 0.0, 1.0],
            ..ray
        }
        .intersects(&bounds));
        assert!(!RaySelection {
            origin: [0.0, 2.0, 10.0],
            ..ray
        }
        .intersects(&bounds));
    }
}
