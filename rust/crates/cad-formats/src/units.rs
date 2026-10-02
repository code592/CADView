/// Canonical IDs for AutoCAD `$INSUNITS` values. Code 0 is intentionally
/// unknown: neither metric/imperial defaults nor locale are valid evidence for
/// a drawing's physical scale.
pub(crate) fn autocad_unit_id(code: i16) -> Option<&'static str> {
    match code {
        1 => Some("in"),
        2 => Some("ft"),
        3 => Some("mi"),
        4 => Some("mm"),
        5 => Some("cm"),
        6 => Some("m"),
        7 => Some("km"),
        8 => Some("microin"),
        9 => Some("mil"),
        10 => Some("yd"),
        11 => Some("angstrom"),
        12 => Some("nm"),
        13 => Some("micron"),
        14 => Some("dm"),
        15 => Some("dam"),
        16 => Some("hm"),
        17 => Some("gm"),
        18 => Some("au"),
        19 => Some("ly"),
        20 => Some("pc"),
        21 => Some("ft_us"),
        22 => Some("in_us"),
        23 => Some("yd_us"),
        24 => Some("mi_us"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_autocad_units_without_guessing_unitless_drawings() {
        assert_eq!(autocad_unit_id(0), None);
        assert_eq!(autocad_unit_id(1), Some("in"));
        assert_eq!(autocad_unit_id(4), Some("mm"));
        assert_eq!(autocad_unit_id(6), Some("m"));
        assert_eq!(autocad_unit_id(21), Some("ft_us"));
        assert_eq!(autocad_unit_id(24), Some("mi_us"));
        assert_eq!(autocad_unit_id(25), None);
    }
}
