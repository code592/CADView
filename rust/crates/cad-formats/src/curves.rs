//! Format-independent curve tessellation shared by the DXF and DWG adapters.

use cad_core::Point2;
use std::f64::consts::TAU;

/// Raw SPLINE data in WCS. Weights may be empty (non-rational).
pub(crate) struct SplineSource<'a> {
    pub degree: i32,
    pub knots: &'a [f64],
    pub control_points: &'a [[f64; 3]],
    pub weights: &'a [f64],
    pub fit_points: &'a [[f64; 3]],
    pub closed: bool,
}

pub(crate) fn tessellate_spline(spline: &SplineSource<'_>) -> Vec<Point2> {
    let controls = spline.control_points;
    if controls.len() >= 2 {
        let degree = (spline.degree.max(1) as usize).min(controls.len().saturating_sub(1));
        let required_knots = controls.len() + degree + 1;
        if spline.knots.len() >= required_knots {
            let start = spline.knots[degree];
            let end = spline.knots[controls.len()];
            if start.is_finite() && end.is_finite() && end > start {
                let samples = (controls.len() * 8).clamp(24, 256);
                let mut points = Vec::with_capacity(samples + 1);
                for sample in 0..=samples {
                    let parameter = if sample == samples {
                        end
                    } else {
                        start + (end - start) * sample as f64 / samples as f64
                    };
                    if let Some(value) = evaluate_nurbs(spline, degree, parameter) {
                        points.push(Point2::new(value[0], value[1]));
                    }
                }
                if points.len() >= 2 {
                    return points;
                }
            }
        }
    }

    // Fit-point-only splines do not contain enough information for exact
    // reconstruction. Interpolating them still preserves every supplied point
    // and is considerably closer to CAD output than treating them as missing.
    let source = if spline.fit_points.len() >= 2 {
        spline.fit_points
    } else {
        controls
    };
    catmull_rom_points(source, spline.closed)
}

fn evaluate_nurbs(spline: &SplineSource<'_>, degree: usize, parameter: f64) -> Option<[f64; 3]> {
    let controls = spline.control_points;
    let knots = spline.knots;
    let control_count = controls.len();
    if control_count < 2 || knots.len() < control_count + degree + 1 {
        return None;
    }
    let last = control_count - 1;
    let span = if parameter >= knots[control_count] {
        last
    } else {
        (degree..=last).find(|&index| parameter >= knots[index] && parameter < knots[index + 1])?
    };
    let mut values = Vec::with_capacity(degree + 1);
    for offset in 0..=degree {
        let index = span - degree + offset;
        let weight = spline.weights.get(index).copied().unwrap_or(1.0);
        let control = controls[index];
        values.push([
            control[0] * weight,
            control[1] * weight,
            control[2] * weight,
            weight,
        ]);
    }
    for level in 1..=degree {
        for offset in (level..=degree).rev() {
            let index = span - degree + offset;
            let denominator = knots[index + degree - level + 1] - knots[index];
            let alpha = if denominator.abs() < 1e-14 {
                0.0
            } else {
                ((parameter - knots[index]) / denominator).clamp(0.0, 1.0)
            };
            let previous = values[offset - 1];
            for (value, previous) in values[offset].iter_mut().zip(previous) {
                *value = previous * (1.0 - alpha) + *value * alpha;
            }
        }
    }
    let value = values[degree];
    if value[3].abs() < 1e-14 {
        return None;
    }
    Some([
        value[0] / value[3],
        value[1] / value[3],
        value[2] / value[3],
    ])
}

fn catmull_rom_points(source: &[[f64; 3]], closed: bool) -> Vec<Point2> {
    if source.len() < 2 {
        return source
            .iter()
            .map(|value| Point2::new(value[0], value[1]))
            .collect();
    }
    let mut output = Vec::with_capacity((source.len() - 1) * 8 + 1);
    let segments = if closed {
        source.len()
    } else {
        source.len() - 1
    };
    for segment in 0..segments {
        let p0 = if segment == 0 {
            if closed {
                source[source.len() - 1]
            } else {
                source[0]
            }
        } else {
            source[segment - 1]
        };
        let p1 = source[segment];
        let p2 = source[(segment + 1) % source.len()];
        let p3 = if segment + 2 < source.len() {
            source[segment + 2]
        } else if closed {
            source[(segment + 2) % source.len()]
        } else {
            p2
        };
        for step in 0..8 {
            if segment > 0 && step == 0 {
                continue;
            }
            let t = step as f64 / 8.0;
            let t2 = t * t;
            let t3 = t2 * t;
            let sample = |axis: usize| {
                (p1[axis] * 2.0
                    + (p2[axis] - p0[axis]) * t
                    + (p0[axis] * 2.0 - p1[axis] * 5.0 + p2[axis] * 4.0 - p3[axis]) * t2
                    + (p3[axis] - p0[axis] + (p1[axis] - p2[axis]) * 3.0) * t3)
                    * 0.5
            };
            output.push(Point2::new(sample(0), sample(1)));
        }
    }
    let end = if closed {
        source[0]
    } else {
        *source.last().unwrap()
    };
    output.push(Point2::new(end[0], end[1]));
    output
}

/// Tessellates a WCS ELLIPSE (or elliptical arc). The minor axis is
/// `normal × major` scaled by the ratio; parameters run counter-clockwise
/// around the normal. Returns the points and whether the curve is closed.
pub(crate) fn tessellate_ellipse(
    center: [f64; 3],
    major: [f64; 3],
    normal: [f64; 3],
    minor_axis_ratio: f64,
    start_parameter: f64,
    end_parameter: f64,
) -> (Vec<Point2>, bool) {
    let sweep = (end_parameter - start_parameter).rem_euclid(TAU);
    let full = sweep.abs() < 1e-9;
    let sweep = if full { TAU } else { sweep };
    let major_length = major.iter().map(|v| v * v).sum::<f64>().sqrt();
    let normal_length = normal.iter().map(|v| v * v).sum::<f64>().sqrt();
    let minor = if major_length > 1e-12 && normal_length > 1e-12 {
        let n = normal.map(|v| v / normal_length);
        let m = major.map(|v| v / major_length);
        let scale = major_length * minor_axis_ratio;
        [
            (n[1] * m[2] - n[2] * m[1]) * scale,
            (n[2] * m[0] - n[0] * m[2]) * scale,
            (n[0] * m[1] - n[1] * m[0]) * scale,
        ]
    } else {
        [0.0; 3]
    };
    let points = (0..=64)
        .map(|index| {
            let parameter = start_parameter + sweep * index as f64 / 64.0;
            let (sin, cos) = parameter.sin_cos();
            Point2::new(
                center[0] + major[0] * cos + minor[0] * sin,
                center[1] + major[1] * cos + minor[1] * sin,
            )
        })
        .collect();
    (points, full)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamped_quadratic_bezier_matches_the_closed_form() {
        let controls = [[0.0, 0.0, 0.0], [1.0, 2.0, 0.0], [2.0, 0.0, 0.0]];
        let points = tessellate_spline(&SplineSource {
            degree: 2,
            knots: &[0.0, 0.0, 0.0, 1.0, 1.0, 1.0],
            control_points: &controls,
            weights: &[],
            fit_points: &[],
            closed: false,
        });
        assert_eq!(points.first(), Some(&Point2::new(0.0, 0.0)));
        assert_eq!(points.last(), Some(&Point2::new(2.0, 0.0)));
        for point in &points {
            // B(t) = (2t, 4t(1-t)), so y = x(2 - x).
            assert!((point.y - point.x * (2.0 - point.x)).abs() < 1e-12);
        }
    }

    #[test]
    fn rational_quadratic_reproduces_a_quarter_circle() {
        let w = std::f64::consts::FRAC_1_SQRT_2;
        let controls = [[1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [0.0, 1.0, 0.0]];
        let points = tessellate_spline(&SplineSource {
            degree: 2,
            knots: &[0.0, 0.0, 0.0, 1.0, 1.0, 1.0],
            control_points: &controls,
            weights: &[1.0, w, 1.0],
            fit_points: &[],
            closed: false,
        });
        for point in &points {
            assert!((point.x.hypot(point.y) - 1.0).abs() < 1e-12);
        }
    }

    #[test]
    fn ellipse_arc_uses_the_normal_for_its_minor_axis() {
        let (points, closed) = tessellate_ellipse(
            [10.0, 0.0, 0.0],
            [4.0, 0.0, 0.0],
            [0.0, 0.0, -1.0],
            0.5,
            0.0,
            std::f64::consts::FRAC_PI_2,
        );
        assert!(!closed);
        // A -Z normal puts the minor axis on -Y: the quarter ends at (10, -2).
        let last = points.last().unwrap();
        assert!((last.x - 10.0).abs() < 1e-12 && (last.y + 2.0).abs() < 1e-12);
    }
}
