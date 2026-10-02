//! CAD linetype patterns for the scene's dashed rendering.

/// Most elements a pattern may have; longer patterns are drawn continuous.
const MAX_ELEMENTS: usize = 32;

/// `true` for the names that mean a continuous line or defer to the owner.
pub(crate) fn is_continuous(name: &str) -> bool {
    let name = name.trim();
    name.is_empty() || name.eq_ignore_ascii_case("Continuous")
}

/// Scales a linetype definition (positive dash, negative gap, zero dot) to
/// drawing units. A pattern without gaps, or one that is invalid, is drawn as
/// a continuous line (an empty pattern).
pub(crate) fn scaled_pattern(elements: &[f64], scale: f64) -> Vec<f64> {
    let scale = if scale.is_finite() && scale > 0.0 {
        scale
    } else {
        1.0
    };
    if elements.is_empty()
        || elements.len() > MAX_ELEMENTS
        || !elements.iter().all(|value| value.is_finite())
        || !elements.iter().any(|value| *value < 0.0)
    {
        return Vec::new();
    }
    let period = elements.iter().map(|value| value.abs()).sum::<f64>() * scale;
    if !period.is_finite() || period <= 0.0 {
        return Vec::new();
    }
    elements.iter().map(|value| value * scale).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn patterns_scale_and_continuous_patterns_are_empty() {
        assert_eq!(scaled_pattern(&[12.7, -6.35], 0.5), [6.35, -3.175]);
        assert_eq!(
            scaled_pattern(&[31.75, -6.35, 6.35, -6.35], 2.0),
            [63.5, -12.7, 12.7, -12.7]
        );
        assert!(
            scaled_pattern(&[5.0], 1.0).is_empty(),
            "no gap is continuous"
        );
        assert!(scaled_pattern(&[], 1.0).is_empty());
        assert!(scaled_pattern(&[f64::NAN, -1.0], 1.0).is_empty());
        assert_eq!(scaled_pattern(&[0.0, -2.0], f64::NAN), [0.0, -2.0]);
        assert!(is_continuous("CONTINUOUS") && is_continuous(" "));
        assert!(!is_continuous("DASHED"));
    }
}
