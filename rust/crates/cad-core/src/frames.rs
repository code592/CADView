//! Detection of drawing frames (title-block borders) used to split exports
//! the way a plot of the drawing is split into sheets.

use crate::{Bounds2, Entity2DGeometry, Point2, Scene2D};
use serde::{Deserialize, Serialize};

/// One sheet: the outer border rectangle of a drawing frame.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DrawingFrame {
    pub bounds: Bounds2,
    /// ISO paper size whose proportions and size (at a round drawing scale)
    /// match the border, such as "A1".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paper: Option<String>,
    /// Drawing units per paper millimetre for [paper], such as 1 or 100.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scale: Option<f64>,
}

const MAX_FRAMES: usize = 256;
const ISO_A: [(&str, f64, f64); 5] = [
    ("A0", 1189.0, 841.0),
    ("A1", 841.0, 594.0),
    ("A2", 594.0, 420.0),
    ("A3", 420.0, 297.0),
    ("A4", 297.0, 210.0),
];

/// Rectangle of an axis-aligned closed polyline with four corners.
fn rectangle(points: &[Point2], closed: bool) -> Option<Bounds2> {
    let mut corners = points.to_vec();
    if corners.len() == 5 {
        let (first, last) = (corners[0], corners[4]);
        let size = corners
            .iter()
            .flat_map(|p| [p.x.abs(), p.y.abs()])
            .fold(1.0, f64::max);
        if (first.x - last.x).abs() > size * 1e-9 || (first.y - last.y).abs() > size * 1e-9 {
            return None;
        }
        corners.pop();
    } else if corners.len() != 4 || !closed {
        return None;
    }
    let min_x = corners.iter().map(|p| p.x).fold(f64::INFINITY, f64::min);
    let max_x = corners
        .iter()
        .map(|p| p.x)
        .fold(f64::NEG_INFINITY, f64::max);
    let min_y = corners.iter().map(|p| p.y).fold(f64::INFINITY, f64::min);
    let max_y = corners
        .iter()
        .map(|p| p.y)
        .fold(f64::NEG_INFINITY, f64::max);
    let (width, height) = (max_x - min_x, max_y - min_y);
    if !(width.is_finite() && height.is_finite()) || width <= 0.0 || height <= 0.0 {
        return None;
    }
    let tolerance = width.max(height) * 1e-6;
    // Every edge is horizontal or vertical, and every corner is a corner of
    // the bounding box.
    for index in 0..4 {
        let (a, b) = (corners[index], corners[(index + 1) % 4]);
        let horizontal = (a.y - b.y).abs() <= tolerance;
        let vertical = (a.x - b.x).abs() <= tolerance;
        if horizontal == vertical {
            return None;
        }
        let on_x = (a.x - min_x).abs() <= tolerance || (a.x - max_x).abs() <= tolerance;
        let on_y = (a.y - min_y).abs() <= tolerance || (a.y - max_y).abs() <= tolerance;
        if !(on_x && on_y) {
            return None;
        }
    }
    Some(Bounds2 {
        min: Point2::new(min_x, min_y),
        max: Point2::new(max_x, max_y),
    })
}

fn width(bounds: &Bounds2) -> f64 {
    bounds.max.x - bounds.min.x
}

fn height(bounds: &Bounds2) -> f64 {
    bounds.max.y - bounds.min.y
}

fn contains(outer: &Bounds2, inner: &Bounds2) -> bool {
    let tolerance = width(outer).max(height(outer)) * 1e-6;
    inner.min.x >= outer.min.x - tolerance
        && inner.min.y >= outer.min.y - tolerance
        && inner.max.x <= outer.max.x + tolerance
        && inner.max.y <= outer.max.y + tolerance
}

/// Paper proportions: ISO A sheets are √2 long; a border drawn inside the
/// sheet margin stays within a few percent of that.
fn paper_proportions(bounds: &Bounds2) -> bool {
    let (long, short) = (
        width(bounds).max(height(bounds)),
        width(bounds).min(height(bounds)),
    );
    let ratio = long / short;
    (ratio / std::f64::consts::SQRT_2 - 1.0).abs() <= 0.06
}

/// The ISO sheet and round drawing scale (1, 2, 2.5 or 5 × 10^k) that match
/// the border within 6% (a border drawn inside the sheet margin is slightly
/// smaller than the sheet).
fn paper_size(bounds: &Bounds2) -> Option<(String, f64)> {
    let (long, short) = (
        width(bounds).max(height(bounds)),
        width(bounds).min(height(bounds)),
    );
    let mut best: Option<(String, f64, f64)> = None;
    for (name, paper_long, paper_short) in ISO_A {
        let scale = long / paper_long;
        let exponent = scale.log10().floor();
        let nice = [1.0, 2.0, 2.5, 5.0, 10.0]
            .iter()
            .map(|mantissa| mantissa * 10f64.powf(exponent))
            .min_by(|a, b| (a - scale).abs().total_cmp(&(b - scale).abs()))?;
        let error = ((long / (paper_long * nice)) - 1.0)
            .abs()
            .max(((short / (paper_short * nice)) - 1.0).abs());
        // Equally good fits (A3 at 1:1 and A1 at 1:2 have the same
        // proportions) prefer the scale closest to 1:1.
        let better = |(_, best_scale, best_error): &(String, f64, f64)| {
            if (error - best_error).abs() <= 0.001 {
                nice.log10().abs() < best_scale.log10().abs()
            } else {
                error < *best_error
            }
        };
        if error <= 0.06 && best.as_ref().is_none_or(better) {
            best = Some((name.to_owned(), nice, error));
        }
    }
    best.map(|(name, scale, _)| (name, scale))
}

/// Finds drawing frames: closed axis-aligned rectangles with paper
/// proportions that contain an inner border at least 80% of their size (the
/// usual title-block outer/inner border pair). Only outermost frames are
/// returned, ordered in rows from the top and left to right within a row.
pub fn detect_drawing_frames(scene: &Scene2D) -> Vec<DrawingFrame> {
    let rectangles = scene
        .entities
        .iter()
        .filter_map(|entity| match &entity.geometry {
            Entity2DGeometry::Polyline { points, closed } => rectangle(points, *closed),
            _ => None,
        })
        .collect::<Vec<_>>();
    let mut frames = rectangles
        .iter()
        .filter(|outer| paper_proportions(outer))
        .filter(|outer| {
            rectangles.iter().any(|inner| {
                inner != *outer
                    && contains(outer, inner)
                    && width(inner) >= 0.8 * width(outer)
                    && height(inner) >= 0.8 * height(outer)
                    && (width(inner) < width(outer) || height(inner) < height(outer))
            })
        })
        .cloned()
        .collect::<Vec<_>>();
    frames.dedup_by(|a, b| a == b);
    let outermost = frames
        .iter()
        .filter(|frame| {
            !frames
                .iter()
                .any(|other| other != *frame && contains(other, frame))
        })
        .cloned()
        .collect::<Vec<_>>();
    let mut outermost = outermost;
    outermost.dedup_by(|a, b| a == b);
    // Rows: frames whose vertical extents overlap by half share a row.
    outermost.sort_by(|a, b| b.max.y.total_cmp(&a.max.y));
    let mut rows: Vec<Vec<Bounds2>> = Vec::new();
    for frame in outermost {
        match rows.iter_mut().find(|row| {
            let top = row[0].max.y.min(frame.max.y);
            let bottom = row[0].min.y.max(frame.min.y);
            top - bottom >= 0.5 * height(&frame).min(height(&row[0]))
        }) {
            Some(row) => row.push(frame),
            None => rows.push(vec![frame]),
        }
    }
    rows.into_iter()
        .flat_map(|mut row| {
            row.sort_by(|a, b| a.min.x.total_cmp(&b.min.x));
            row
        })
        .take(MAX_FRAMES)
        .map(|bounds| {
            let paper = paper_size(&bounds);
            DrawingFrame {
                bounds,
                paper: paper.as_ref().map(|(name, _)| name.clone()),
                scale: paper.map(|(_, scale)| scale),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Entity2D, Layer};

    fn rect(x: f64, y: f64, w: f64, h: f64, five_points: bool) -> Entity2D {
        let mut points = vec![
            Point2::new(x, y),
            Point2::new(x + w, y),
            Point2::new(x + w, y + h),
            Point2::new(x, y + h),
        ];
        if five_points {
            points.push(Point2::new(x, y));
        }
        Entity2D {
            id: 1,
            layer_id: 1,
            color_argb: 0xffffffff,
            stroke_width: 0.0,
            filled: false,
            dash: Vec::new(),
            geometry: Entity2DGeometry::Polyline {
                points,
                closed: !five_points,
            },
        }
    }

    fn scene(entities: Vec<Entity2D>) -> Scene2D {
        Scene2D {
            layers: vec![Layer {
                id: 1,
                name: "0".to_owned(),
                visible: true,
                color_argb: 0xffffffff,
            }],
            entities,
            bounds: None,
        }
    }

    #[test]
    fn title_block_borders_are_found_outermost_and_in_reading_order() {
        // The A1/A2/A3 sample's outer borders (sheet minus margin) with their
        // inner borders, laid out right to left to check ordering.
        let frames = detect_drawing_frames(&scene(vec![
            rect(2527.2, 1698.34, 409.93, 283.36, false),
            rect(2552.4, 1701.52, 380.0, 277.0, false),
            rect(790.64, 1594.94, 831.0, 584.03, false),
            rect(811.64, 1604.95, 800.0, 564.0, false),
            rect(1791.81, 1648.14, 584.03, 410.04, true),
            rect(1811.84, 1653.16, 559.0, 400.0, false),
            // A lone rectangle with paper proportions but no inner border.
            rect(0.0, 0.0, 141.4, 100.0, false),
        ]));
        let summary = frames
            .iter()
            .map(|frame| (frame.paper.as_deref(), frame.bounds.min.x))
            .collect::<Vec<_>>();
        assert_eq!(
            summary,
            [
                (Some("A1"), 790.64),
                (Some("A2"), 1791.81),
                (Some("A3"), 2527.2)
            ]
        );
        assert!(frames.iter().all(|frame| frame.scale == Some(1.0)));
    }

    #[test]
    fn scaled_frames_report_their_drawing_scale_and_rows() {
        let frames = detect_drawing_frames(&scene(vec![
            rect(0.0, 0.0, 42000.0, 29700.0, false),
            rect(2500.0, 500.0, 39000.0, 28700.0, false),
            rect(0.0, 40000.0, 42000.0, 29700.0, false),
            rect(2500.0, 40500.0, 39000.0, 28700.0, false),
        ]));
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].bounds.min.y, 40000.0, "top row first");
        assert_eq!(frames[0].paper.as_deref(), Some("A3"));
        assert_eq!(frames[0].scale, Some(100.0));
    }

    #[test]
    fn non_rectangles_and_rotated_borders_are_ignored() {
        let mut skewed = rect(0.0, 0.0, 841.0, 594.0, false);
        if let Entity2DGeometry::Polyline { points, .. } = &mut skewed.geometry {
            points[2].x += 5.0;
        }
        assert!(
            detect_drawing_frames(&scene(vec![skewed, rect(10.0, 10.0, 800.0, 560.0, false)]))
                .is_empty()
        );
    }
}
