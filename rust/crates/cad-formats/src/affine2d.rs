//! Affine transforms of normalized 2D scene geometry, used to expand block
//! references after each child has been normalized in block coordinates.

use cad_core::TextGeometry2D;
use cad_core::{Entity2DGeometry, Point2, TextPlane2D};
use std::f64::consts::{PI, TAU};

/// x' = a·x + c·y + tx, y' = b·x + d·y + ty.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Affine2 {
    pub a: f64,
    pub b: f64,
    pub c: f64,
    pub d: f64,
    pub tx: f64,
    pub ty: f64,
}

impl Affine2 {
    pub const IDENTITY: Self = Self {
        a: 1.0,
        b: 0.0,
        c: 0.0,
        d: 1.0,
        tx: 0.0,
        ty: 0.0,
    };

    pub fn translation(x: f64, y: f64) -> Self {
        Self {
            tx: x,
            ty: y,
            ..Self::IDENTITY
        }
    }

    /// `self ∘ inner`: apply [inner] first, then [self].
    pub fn then_after(&self, inner: &Self) -> Self {
        Self {
            a: self.a * inner.a + self.c * inner.b,
            b: self.b * inner.a + self.d * inner.b,
            c: self.a * inner.c + self.c * inner.d,
            d: self.b * inner.c + self.d * inner.d,
            tx: self.a * inner.tx + self.c * inner.ty + self.tx,
            ty: self.b * inner.tx + self.d * inner.ty + self.ty,
        }
    }

    pub fn apply(&self, point: Point2) -> Point2 {
        Point2::new(
            self.a * point.x + self.c * point.y + self.tx,
            self.b * point.x + self.d * point.y + self.ty,
        )
    }

    pub fn is_identity(&self) -> bool {
        *self == Self::IDENTITY
    }

    pub fn is_similarity(&self) -> bool {
        self.similarity_scale().is_some()
    }

    fn determinant(&self) -> f64 {
        self.a * self.d - self.b * self.c
    }

    fn is_finite(&self) -> bool {
        [self.a, self.b, self.c, self.d, self.tx, self.ty]
            .iter()
            .all(|value| value.is_finite())
    }

    /// Uniform scale of a similarity (rotation/reflection plus uniform
    /// scale), or None when the linear part distorts circles into ellipses.
    fn similarity_scale(&self) -> Option<f64> {
        let first = self.a.hypot(self.b);
        let second = self.c.hypot(self.d);
        let scale = first.max(second);
        if scale <= 0.0 || !scale.is_finite() {
            return None;
        }
        let dot = self.a * self.c + self.b * self.d;
        ((first - second).abs() <= scale * 1e-9 && dot.abs() <= scale * scale * 1e-9)
            .then_some((first + second) / 2.0)
    }
}

fn arc_points(center: Point2, radius: f64, start: f64, sweep: f64) -> Vec<Point2> {
    // At most five degrees per chord, matching OCS arc projection.
    let steps = (sweep / (PI / 36.0)).ceil().clamp(2.0, 72.0) as usize;
    (0..=steps)
        .map(|index| {
            let (sin, cos) = (start + sweep * index as f64 / steps as f64).sin_cos();
            Point2::new(center.x + radius * cos, center.y + radius * sin)
        })
        .collect()
}

/// Transforms one normalized geometry. Circles and arcs remain exact under a
/// similarity (a reflection swaps the arc's endpoints to stay counter-clockwise)
/// and become tessellated ellipses under a non-uniform scale. Text keeps its
/// local layout and composes the transform's linear part into its plane.
pub(crate) fn transform_geometry(
    geometry: Entity2DGeometry,
    transform: &Affine2,
) -> Option<Entity2DGeometry> {
    if transform.is_identity() {
        return Some(geometry);
    }
    if !transform.is_finite() || transform.determinant().abs() < 1e-300 {
        return None;
    }
    let result = match geometry {
        Entity2DGeometry::Point { position } => Entity2DGeometry::Point {
            position: transform.apply(position),
        },
        Entity2DGeometry::Line { start, end } => Entity2DGeometry::Line {
            start: transform.apply(start),
            end: transform.apply(end),
        },
        Entity2DGeometry::Polyline { points, closed } => Entity2DGeometry::Polyline {
            points: points.into_iter().map(|p| transform.apply(p)).collect(),
            closed,
        },
        Entity2DGeometry::Circle { center, radius } => match transform.similarity_scale() {
            Some(scale) => Entity2DGeometry::Circle {
                center: transform.apply(center),
                radius: radius * scale,
            },
            None => {
                let mut points = arc_points(center, radius, 0.0, TAU);
                points.pop();
                Entity2DGeometry::Polyline {
                    points: points.into_iter().map(|p| transform.apply(p)).collect(),
                    closed: true,
                }
            }
        },
        Entity2DGeometry::Arc {
            center,
            radius,
            start_angle,
            end_angle,
        } => match transform.similarity_scale() {
            Some(scale) => {
                let map = |angle: f64| {
                    let (sin, cos) = angle.sin_cos();
                    (transform.b * cos + transform.d * sin)
                        .atan2(transform.a * cos + transform.c * sin)
                };
                let (start_angle, end_angle) = if start_angle == end_angle {
                    let mapped = map(start_angle);
                    (mapped, mapped)
                } else if transform.determinant() < 0.0 {
                    (map(end_angle), map(start_angle))
                } else {
                    (map(start_angle), map(end_angle))
                };
                Entity2DGeometry::Arc {
                    center: transform.apply(center),
                    radius: radius * scale,
                    start_angle,
                    end_angle,
                }
            }
            None => {
                let sweep = (end_angle - start_angle).rem_euclid(TAU);
                let full = sweep <= 1e-12;
                let mut points =
                    arc_points(center, radius, start_angle, if full { TAU } else { sweep });
                if full {
                    points.pop();
                }
                Entity2DGeometry::Polyline {
                    points: points.into_iter().map(|p| transform.apply(p)).collect(),
                    closed: full,
                }
            }
        },
        Entity2DGeometry::Text(text_geometry) => {
            let TextGeometry2D {
                origin,
                value,
                height,
                height_reference,
                rotation,
                width_factor,
                oblique_angle,
                horizontal_alignment,
                vertical_alignment,
                target_width,
                uniform_fit,
                wrap_width,
                line_spacing,
                columns,
                background,
                mirrored_x,
                mirrored_y,
                font_family,
                shx,
                plane,
                text_runs,
                text_warnings,
            } = *text_geometry;
            // The painter places glyphs at origin + plane · R(rotation) · local.
            let p = plane.unwrap_or(TextPlane2D {
                xx: 1.0,
                xy: 0.0,
                yx: 0.0,
                yy: 1.0,
            });
            let composed = TextPlane2D {
                xx: transform.a * p.xx + transform.c * p.yx,
                xy: transform.a * p.xy + transform.c * p.yy,
                yx: transform.b * p.xx + transform.d * p.yx,
                yy: transform.b * p.xy + transform.d * p.yy,
            };
            let identity = composed.xx == 1.0
                && composed.xy == 0.0
                && composed.yx == 0.0
                && composed.yy == 1.0;
            Entity2DGeometry::Text(Box::new(TextGeometry2D {
                origin: transform.apply(origin),
                value,
                height,
                height_reference,
                rotation,
                width_factor,
                oblique_angle,
                horizontal_alignment,
                vertical_alignment,
                target_width,
                uniform_fit,
                wrap_width,
                line_spacing,
                columns,
                background,
                mirrored_x,
                mirrored_y,
                font_family,
                shx,
                plane: (!identity).then_some(composed),
                text_runs,
                text_warnings,
            }))
        }
    };
    Some(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rotate_scale(angle: f64, sx: f64, sy: f64, tx: f64, ty: f64) -> Affine2 {
        let (sin, cos) = angle.sin_cos();
        Affine2 {
            a: cos * sx,
            b: sin * sx,
            c: -sin * sy,
            d: cos * sy,
            tx,
            ty,
        }
    }

    fn arc_endpoints(geometry: &Entity2DGeometry) -> (Point2, Point2) {
        let Entity2DGeometry::Arc {
            center,
            radius,
            start_angle,
            end_angle,
        } = geometry
        else {
            panic!("{geometry:?}")
        };
        let at = |angle: f64| {
            Point2::new(
                center.x + radius * angle.cos(),
                center.y + radius * angle.sin(),
            )
        };
        (at(*start_angle), at(*end_angle))
    }

    fn near(a: Point2, b: Point2) -> bool {
        (a.x - b.x).abs() < 1e-9 && (a.y - b.y).abs() < 1e-9
    }

    #[test]
    fn similarity_keeps_arcs_and_reflection_swaps_endpoints() {
        let arc = Entity2DGeometry::Arc {
            center: Point2::new(1.0, 0.0),
            radius: 1.0,
            start_angle: 0.0,
            end_angle: PI / 2.0,
        };
        // Original endpoints (2, 0) and (1, 1).
        for transform in [
            rotate_scale(0.7, 2.0, 2.0, 5.0, -3.0),
            rotate_scale(0.7, -2.0, 2.0, 5.0, -3.0),
        ] {
            let mapped = transform_geometry(arc.clone(), &transform).unwrap();
            let (start, end) = arc_endpoints(&mapped);
            let expected = [
                transform.apply(Point2::new(2.0, 0.0)),
                transform.apply(Point2::new(1.0, 1.0)),
            ];
            if transform.determinant() > 0.0 {
                assert!(near(start, expected[0]) && near(end, expected[1]));
            } else {
                assert!(near(start, expected[1]) && near(end, expected[0]));
            }
        }
    }

    #[test]
    fn non_uniform_scale_turns_circles_into_ellipses() {
        let transform = rotate_scale(0.0, 3.0, 1.0, 0.0, 0.0);
        let Some(Entity2DGeometry::Polyline { points, closed }) = transform_geometry(
            Entity2DGeometry::Circle {
                center: Point2::new(0.0, 0.0),
                radius: 2.0,
            },
            &transform,
        ) else {
            panic!()
        };
        assert!(closed);
        for point in points {
            let value = (point.x / 6.0).powi(2) + (point.y / 2.0).powi(2);
            assert!((value - 1.0).abs() < 1e-12);
        }
    }

    #[test]
    fn composition_applies_inner_first() {
        let inner = rotate_scale(PI / 2.0, 1.0, 1.0, 1.0, 0.0);
        let outer = Affine2::translation(10.0, 20.0);
        let composed = outer.then_after(&inner);
        let point = Point2::new(1.0, 0.0);
        assert!(near(composed.apply(point), outer.apply(inner.apply(point))));
    }
}
