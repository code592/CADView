use crate::{Bounds2, Scene2D};
use rstar::{RTree, RTreeObject, AABB};

#[derive(Debug, Clone, Copy)]
struct IndexedEntity {
    id: u64,
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
    pub fn build(scene: &Scene2D) -> Self {
        let entries = scene
            .entities
            .iter()
            .filter_map(|entity| {
                entity.bounds().map(|bounds| IndexedEntity {
                    id: entity.id,
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
                    geometry: Entity2DGeometry::Line {
                        start: Point2::new(0.0, 0.0),
                        end: Point2::new(10.0, 10.0),
                    },
                },
                Entity2D {
                    id: 2,
                    layer_id: 0,
                    color_argb: 0,
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
    }
}
