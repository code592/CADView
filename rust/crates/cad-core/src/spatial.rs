use crate::{Bounds2, Entity2D, Scene2D};
use rstar::{RTree, RTreeObject, AABB};

#[derive(Debug, Clone, Copy)]
struct IndexedEntity {
    id: u64,
    source_index: usize,
    envelope: AABB<[f64; 2]>,
}

impl RTreeObject for IndexedEntity {
    type Envelope = AABB<[f64; 2]>;

    fn envelope(&self) -> Self::Envelope {
        self.envelope
    }
}

/// Runtime-only R-tree used for viewport culling, snapping and hit testing.
/// It stays outside the serialized scene so caches remain implementation-neutral.
#[derive(Debug, Default)]
pub struct SceneIndex2D {
    tree: RTree<IndexedEntity>,
}

impl SceneIndex2D {
    /// Temporary analytic envelopes, with returned indices in input order.
    /// Used by local intersection queries without constructing scene entities.
    pub fn from_bounds(bounds: impl IntoIterator<Item = Bounds2>) -> Self {
        let entries = bounds
            .into_iter()
            .enumerate()
            .map(|(source_index, bounds)| IndexedEntity {
                id: source_index as u64,
                source_index,
                envelope: to_envelope(bounds),
            })
            .collect();
        Self {
            tree: RTree::bulk_load(entries),
        }
    }

    pub fn build(scene: &Scene2D) -> Self {
        Self::build_with_bounds(scene, Entity2D::bounds)
    }

    /// UI-independent hook for envelopes measured by the active text shaper.
    /// Parsers need no Flutter/font dependency; all other geometry keeps its
    /// analytic domain bounds.
    pub fn build_with_bounds(
        scene: &Scene2D,
        bounds_for: impl Fn(&Entity2D) -> Option<Bounds2>,
    ) -> Self {
        let entries = scene
            .entities
            .iter()
            .enumerate()
            .filter_map(|(source_index, entity)| {
                bounds_for(entity).map(|bounds| IndexedEntity {
                    id: entity.id,
                    source_index,
                    envelope: to_envelope(bounds),
                })
            })
            .collect();
        Self {
            tree: RTree::bulk_load(entries),
        }
    }

    pub fn query(&self, bounds: Bounds2) -> Vec<u64> {
        self.tree
            .locate_in_envelope_intersecting(&to_envelope(bounds))
            .map(|entry| entry.id)
            .collect()
    }

    /// Resolve candidates directly into the retained scene, without scanning
    /// every entity to find their ids. Source order preserves compositing and
    /// deterministic selection/snap ties (R-tree traversal order does not).
    pub fn query_indices(&self, bounds: Bounds2) -> Vec<usize> {
        let mut indices = self
            .tree
            .locate_in_envelope_intersecting(&to_envelope(bounds))
            .map(|entry| entry.source_index)
            .collect::<Vec<_>>();
        indices.sort_unstable();
        indices
    }

    pub fn len(&self) -> usize {
        self.tree.size()
    }

    pub fn is_empty(&self) -> bool {
        self.tree.size() == 0
    }
}

fn to_envelope(bounds: Bounds2) -> AABB<[f64; 2]> {
    AABB::from_corners([bounds.min.x, bounds.min.y], [bounds.max.x, bounds.max.y])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Entity2D, Entity2DGeometry, Point2};

    #[test]
    fn spatial_query_returns_only_intersecting_entities() {
        let scene = Scene2D {
            entities: vec![
                Entity2D {
                    id: 1,
                    layer_id: 0,
                    color_argb: 0,
                    stroke_width: 0.0,
                    filled: false,
                    dash: Vec::new(),
                    geometry: Entity2DGeometry::Line {
                        start: Point2::new(0.0, 0.0),
                        end: Point2::new(10.0, 10.0),
                    },
                },
                Entity2D {
                    id: 2,
                    layer_id: 0,
                    color_argb: 0,
                    stroke_width: 0.0,
                    filled: false,
                    dash: Vec::new(),
                    geometry: Entity2DGeometry::Point {
                        position: Point2::new(100.0, 100.0),
                    },
                },
            ],
            ..Scene2D::default()
        };
        let index = SceneIndex2D::build(&scene);
        let ids = index.query(Bounds2 {
            min: Point2::new(-1.0, -1.0),
            max: Point2::new(11.0, 11.0),
        });
        assert_eq!(ids, vec![1]);
        assert_eq!(
            index.query_indices(Bounds2 {
                min: Point2::new(-1.0, -1.0),
                max: Point2::new(101.0, 101.0),
            }),
            vec![0, 1]
        );
    }

    #[test]
    fn source_indices_skip_invalid_bounds_without_reordering_sparse_ids() {
        let mut scene = Scene2D::default();
        for (id, x) in [(90, 0.0), (2, f64::NAN), (70, 2.0), (3, 1.0)] {
            scene.entities.push(Entity2D {
                id,
                layer_id: 0,
                color_argb: 0,
                stroke_width: 0.0,
                filled: false,
                dash: vec![],
                geometry: Entity2DGeometry::Point {
                    position: Point2::new(x, 0.0),
                },
            });
        }
        let index = SceneIndex2D::build_with_bounds(&scene, |entity| {
            entity.bounds().filter(|b| b.min.x.is_finite())
        });
        let indices = index.query_indices(Bounds2 {
            min: Point2::new(-1.0, -1.0),
            max: Point2::new(3.0, 1.0),
        });
        assert_eq!(indices, vec![0, 2, 3]);
        assert_eq!(
            indices
                .into_iter()
                .map(|i| scene.entities[i].id)
                .collect::<Vec<_>>(),
            vec![90, 70, 3]
        );
    }
}
