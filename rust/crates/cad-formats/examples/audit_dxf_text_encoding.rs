//! A font cannot repair text already decoded with the wrong code page.
//! Keep this isolated audit separate from rendering/font asset checks.
use cad_core::{CancellationToken, Entity2DGeometry, FormatAdapter, SceneDocument};
use cad_formats::DxfAdapter;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // R2000, ANSI_1251: these six bytes spell the Cyrillic label "Размер".
    let bytes = b"0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n9\n$DWGCODEPAGE\n3\nANSI_1251\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nTEXT\n8\n0\n10\n0\n20\n0\n40\n10\n1\n\xD0\xE0\xE7\xEC\xE5\xF0\n0\nENDSEC\n0\nEOF\n";
    let opened = DxfAdapter.open(
        bytes,
        "cyrillic-r2000.dxf",
        None,
        &CancellationToken::default(),
        None,
    )?;
    let SceneDocument::TwoD(scene) = opened.scene else {
        return Err("expected Scene2D".into());
    };
    let Entity2DGeometry::Text { value, .. } = &scene.entities[0].geometry else {
        return Err("expected text".into());
    };
    println!("Expected: Размер; decoded: {value}");
    if value != "Размер" {
        return Err("legacy DXF text code page is not honored".into());
    }
    // Independently authored binary group pairs, not a writer round-trip.
    let mut binary = b"AutoCAD Binary DXF\r\n\x1a\0".to_vec();
    for (code, text) in [
        (0_u16, "SECTION"),
        (2, "HEADER"),
        (9, "$ACADVER"),
        (1, "AC1021"),
        (9, "$DWGCODEPAGE"),
        (3, "ANSI_1252"),
        (0, "ENDSEC"),
        (0, "SECTION"),
        (2, "ENTITIES"),
        (0, "TEXT"),
        (8, "0"),
    ] {
        binary.extend_from_slice(&code.to_le_bytes());
        binary.extend_from_slice(text.as_bytes());
        binary.push(0);
    }
    for (code, number) in [(10_u16, 0_f64), (20, 0.), (40, 10.)] {
        binary.extend_from_slice(&code.to_le_bytes());
        binary.extend_from_slice(&number.to_le_bytes());
    }
    for (code, text) in [(1_u16, "Размер 中文"), (0, "ENDSEC"), (0, "EOF")] {
        binary.extend_from_slice(&code.to_le_bytes());
        binary.extend_from_slice(text.as_bytes());
        binary.push(0);
    }
    let opened = DxfAdapter.open(
        &binary,
        "unicode-binary.dxf",
        None,
        &CancellationToken::default(),
        None,
    )?;
    let SceneDocument::TwoD(scene) = opened.scene else {
        return Err("expected Scene2D".into());
    };
    let Entity2DGeometry::Text { value, .. } = &scene.entities[0].geometry else {
        return Err("expected text".into());
    };
    println!("Binary UTF-8 expected: Размер 中文; decoded: {value}");
    if value != "Размер 中文" {
        return Err("binary DXF text decoding is incorrect".into());
    }
    Ok(())
}
