use crate::{Point2, Point3};

pub fn distance_2d(a: Point2, b: Point2) -> f64 {
    (b.x - a.x).hypot(b.y - a.y)
}

pub fn distance_3d(a: Point3, b: Point3) -> f64 {
    ((b.x - a.x).powi(2) + (b.y - a.y).powi(2) + (b.z - a.z).powi(2)).sqrt()
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
    }
}
