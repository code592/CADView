use cad_core::{Point2, TextPlane2D};

pub(crate) type Axes3 = [[f64; 3]; 3];

pub(crate) fn unit(vector: [f64; 3]) -> Option<[f64; 3]> {
    if !vector.iter().all(|value| value.is_finite()) {
        return None;
    }
    let scale = vector.iter().map(|v| v.abs()).fold(0.0, f64::max);
    if scale == 0.0 {
        return None;
    }
    let v = vector.map(|v| v / scale);
    let length = v[0].hypot(v[1]).hypot(v[2]);
    Some(v.map(|v| v / length))
}

fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

/// Autodesk arbitrary-axis algorithm, including the exact 1/64 polar cap.
pub(crate) fn ocs_axes(normal: [f64; 3]) -> Option<Axes3> {
    let n = unit(normal)?;
    let seed = if n[0].abs() < 1.0 / 64.0 && n[1].abs() < 1.0 / 64.0 {
        [0.0, 1.0, 0.0]
    } else {
        [0.0, 0.0, 1.0]
    };
    let x = unit(cross(seed, n))?;
    let y = unit(cross(n, x))?;
    Some([x, y, n])
}

pub(crate) fn world_point(axes: Axes3, point: [f64; 3]) -> Point2 {
    Point2::new(
        axes[0][0] * point[0] + axes[1][0] * point[1] + axes[2][0] * point[2],
        axes[0][1] * point[0] + axes[1][1] * point[1] + axes[2][1] * point[2],
    )
}

pub(crate) fn plane(axes: Axes3) -> Option<TextPlane2D> {
    let p = TextPlane2D {
        xx: axes[0][0],
        xy: axes[1][0],
        yx: axes[0][1],
        yy: axes[1][1],
    };
    if p.xx == 1.0 && p.xy == 0.0 && p.yx == 0.0 && p.yy == 1.0 {
        None
    } else {
        Some(p)
    }
}

/// MTEXT's direction vector is WCS, unlike TEXT's OCS alignment points.
pub(crate) fn mtext_axes(normal: [f64; 3], direction: [f64; 3]) -> Option<Axes3> {
    let n = unit(normal)?;
    let d = unit(direction)?;
    let dot = n[0] * d[0] + n[1] * d[1] + n[2] * d[2];
    let x = unit([d[0] - dot * n[0], d[1] - dot * n[1], d[2] - dot * n[2]])?;
    let y = unit(cross(n, x))?;
    Some([x, y, n])
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn arbitrary_axis_handles_negative_z_tilt_and_scale_without_overflow() {
        let axes = ocs_axes([0.0, 0.0, -1.0]).unwrap();
        let origin = world_point(axes, [10.0, 20.0, 30.0]);
        assert_eq!((origin.x, origin.y), (-10.0, 20.0));
        let axes = ocs_axes([0.0, 0.6, 0.8]).unwrap();
        let origin = world_point(axes, [10.0, 20.0, 30.0]);
        assert!((origin.x + 10.0).abs() < 1e-12);
        assert!((origin.y - 2.0).abs() < 1e-12);
        assert!(ocs_axes([0.0, 0.0, 0.0]).is_none());
        assert!(ocs_axes([f64::NAN, 0.0, 1.0]).is_none());
        assert!(ocs_axes([f64::MAX, f64::MAX, f64::MAX]).is_some());
    }
}
