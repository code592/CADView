use cad_core::{CancellationToken, Entity2DGeometry, FormatAdapter, SceneDocument};
use cad_formats::DwgAdapter;
use std::{collections::HashSet, env, path::Path, time::Instant};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = env::args().nth(1).expect("DWG path");
    let started = Instant::now();
    let opened = DwgAdapter.open_path(
        Path::new(&path),
        Path::new(&path)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("drawing.dwg"),
        &CancellationToken::default(),
        None,
    )?;
    let SceneDocument::TwoD(scene) = opened.scene else {
        return Err("DWG did not produce Scene2D".into());
    };
    let bounds = scene.bounds.ok_or("DWG has no displayable bounds")?;
    if ![bounds.min.x, bounds.min.y, bounds.max.x, bounds.max.y]
        .into_iter()
        .all(f64::is_finite)
    {
        return Err("DWG bounds are not finite".into());
    }
    let ids = scene
        .entities
        .iter()
        .map(|entity| entity.id)
        .collect::<HashSet<_>>();
    if ids.len() != scene.entities.len() {
        return Err("DWG normalized entity IDs are not unique".into());
    }
    if ids.iter().any(|id| *id > (1_u64 << 53) - 1) {
        return Err("DWG entity ID exceeds JSON's exact integer range".into());
    }
    let text_count = scene
        .entities
        .iter()
        .filter(|entity| matches!(entity.geometry, Entity2DGeometry::Text { .. }))
        .count();
    let aligned_text_count = scene
        .entities
        .iter()
        .filter(|entity| {
            matches!(
                entity.geometry,
                Entity2DGeometry::Text {
                    target_width: Some(_),
                    ..
                }
            )
        })
        .count();
    let filled_count = scene.entities.iter().filter(|entity| entity.filled).count();

    let file_name = Path::new(&path)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    if file_name == "A1、A2、A3图框.dwg" {
        if scene.entities.len() < 1_100
            || text_count < 300
            || aligned_text_count < 20
            || filled_count < 100
        {
            return Err(format!(
                "title-block regression: entities={}, text={}, fitted={}, filled={}",
                scene.entities.len(),
                text_count,
                aligned_text_count,
                filled_count,
            )
            .into());
        }
        // *D1 stores the correct horizontal 46.6 dimension line. The old
        // generic explode path incorrectly connected its measured corner to
        // the far definition point, creating a conspicuous diagonal triangle.
        if has_line(&scene, (1021.0938, 2027.8369), (1067.6660, 2032.5297), 0.02) {
            return Err("dimension regression: found obsolete definition-point diagonal".into());
        }
        if !has_line(&scene, (1023.5938, 2032.5297), (1065.1660, 2032.5297), 0.02) {
            return Err("dimension regression: exact *D1 dimension line is missing".into());
        }
    }

    println!(
        "PASS\t{}\t{} ms\t{} entities\t{} text\t{} fitted\t{} filled\tbounds {:.3},{:.3}..{:.3},{:.3}",
        file_name,
        started.elapsed().as_millis(),
        scene.entities.len(),
        text_count,
        aligned_text_count,
        filled_count,
        bounds.min.x,
        bounds.min.y,
        bounds.max.x,
        bounds.max.y,
    );
    Ok(())
}

fn has_line(
    scene: &cad_core::Scene2D,
    first: (f64, f64),
    second: (f64, f64),
    tolerance: f64,
) -> bool {
    let near = |point: cad_core::Point2, expected: (f64, f64)| {
        (point.x - expected.0).abs() <= tolerance && (point.y - expected.1).abs() <= tolerance
    };
    scene.entities.iter().any(|entity| match entity.geometry {
        Entity2DGeometry::Line { start, end } => {
            (near(start, first) && near(end, second)) || (near(start, second) && near(end, first))
        }
        _ => false,
    })
}
