//! Versioned, lossless viewport transport. Runtime only; not the disk cache.
use cad_core::{Entity2D, Entity2DGeometry, Mesh3D};
use serde::Serialize;
use std::collections::HashMap;

pub(crate) const MAGIC: &[u8; 8] = b"CAD2D001";
const RECORD_BYTES: usize = 32;
const STYLE_BYTES: usize = 24;

/// 3D runtime transport: small JSON metadata followed by contiguous exact
/// f64 XYZ, native f32 normals and u32 indices. No per-vertex JSON objects.
pub(crate) fn encode_3d(metadata: &str, meshes: &[Mesh3D]) -> Result<Vec<u8>, String> {
    #[derive(Serialize)]
    struct MeshInfo<'a> {
        id: u64,
        name: &'a str,
        material_index: Option<u32>,
        surface_area: Option<f64>,
        closed_manifold: Option<bool>,
        enclosed_volume: Option<f64>,
        volume_centroid: Option<cad_core::Point3>,
    }
    let mut document: serde_json::Value =
        serde_json::from_str(metadata).map_err(|e| e.to_string())?;
    document["scene"]["scene"]["meshes"] = serde_json::to_value(
        meshes
            .iter()
            .map(|mesh| MeshInfo {
                id: mesh.id,
                name: &mesh.name,
                material_index: mesh.material_index,
                surface_area: mesh.surface_area,
                closed_manifold: mesh.closed_manifold,
                enclosed_volume: mesh.enclosed_volume,
                volume_centroid: mesh.volume_centroid,
            })
            .collect::<Vec<_>>(),
    )
    .map_err(|e| e.to_string())?;
    let metadata = serde_json::to_vec(&document).map_err(|e| e.to_string())?;
    let mut positions = 0usize;
    let mut normals = 0usize;
    let mut indices = 0usize;
    for mesh in meshes {
        if mesh.indices.len() % 3 != 0
            || mesh
                .indices
                .iter()
                .any(|&i| i as usize >= mesh.positions.len())
        {
            return Err("invalid mesh topology for scene packet".to_owned());
        }
        positions = positions
            .checked_add(mesh.positions.len())
            .ok_or("packet overflow")?;
        normals = normals
            .checked_add(mesh.normals.len())
            .ok_or("packet overflow")?;
        indices = indices
            .checked_add(mesh.indices.len())
            .ok_or("packet overflow")?;
    }
    let aligned = 32usize
        .checked_add(metadata.len())
        .and_then(|n| n.checked_add(7))
        .ok_or("packet overflow")?
        & !7;
    let capacity = [
        meshes.len().checked_mul(12),
        positions.checked_mul(24),
        normals.checked_mul(12),
        indices.checked_mul(4),
    ]
    .into_iter()
    .try_fold(aligned, |a, b| a.checked_add(b?))
    .ok_or("packet overflow")?;
    // Align the coordinate section independently of the 12-byte directory.
    let coordinate_padding = if meshes.len() % 2 == 1 { 4 } else { 0 };
    let capacity = capacity
        .checked_add(coordinate_padding)
        .ok_or("packet overflow")?;
    if capacity > i32::MAX as usize {
        return Err("viewport packet exceeds bridge limits".to_owned());
    }
    let mut out = Vec::with_capacity(capacity);
    out.extend_from_slice(b"CAD3D001");
    for value in [metadata.len(), meshes.len(), positions, normals, indices, 0] {
        word(&mut out, value)?;
    }
    out.extend_from_slice(&metadata);
    out.resize(aligned, 0);
    for mesh in meshes {
        for value in [mesh.positions.len(), mesh.normals.len(), mesh.indices.len()] {
            word(&mut out, value)?;
        }
    }
    out.resize(out.len() + coordinate_padding, 0);
    for mesh in meshes {
        for p in &mesh.positions {
            doubles(&mut out, [p.x, p.y, p.z]);
        }
    }
    for mesh in meshes {
        for normal in &mesh.normals {
            for value in normal {
                out.extend_from_slice(&value.to_le_bytes());
            }
        }
    }
    for mesh in meshes {
        for value in &mesh.indices {
            out.extend_from_slice(&value.to_le_bytes());
        }
    }
    debug_assert_eq!(capacity, out.len());
    Ok(out)
}

#[derive(Hash, PartialEq, Eq)]
struct StyleKey {
    color: u32,
    width: u64,
    filled: bool,
    dash: Vec<u64>,
}

fn count(value: usize) -> Result<u32, String> {
    u32::try_from(value).map_err(|_| "viewport packet exceeds u32 limits".to_owned())
}
fn word(out: &mut Vec<u8>, value: usize) -> Result<(), String> {
    out.extend_from_slice(&count(value)?.to_le_bytes());
    Ok(())
}
fn doubles(out: &mut Vec<u8>, values: impl IntoIterator<Item = f64>) {
    for value in values {
        out.extend_from_slice(&value.to_le_bytes());
    }
}

pub(crate) fn encode_2d(metadata: &str, entities: &[&Entity2D]) -> Result<Vec<u8>, String> {
    let mut style_ids = HashMap::new();
    let mut styles = Vec::new();
    let mut records = Vec::with_capacity(entities.len() * RECORD_BYTES);
    let mut coords = Vec::new();
    let mut dashes = Vec::new();
    let mut fallback = Vec::new();
    for entity in entities {
        let key = StyleKey {
            color: entity.color_argb,
            width: entity.stroke_width.to_bits(),
            filled: entity.filled,
            dash: entity.dash.iter().map(|v| v.to_bits()).collect(),
        };
        let style_id = *style_ids.entry(key).or_insert_with(|| {
            let id = styles.len();
            styles.push(*entity);
            id
        });
        let coord_start = coords.len() / 8;
        let (kind, flags, start, length) = match &entity.geometry {
            Entity2DGeometry::Point { position } => {
                doubles(&mut coords, [position.x, position.y]);
                (1, 0, coord_start, 2)
            }
            Entity2DGeometry::Line { start, end } => {
                doubles(&mut coords, [start.x, start.y, end.x, end.y]);
                (2, 0, coord_start, 4)
            }
            Entity2DGeometry::Polyline { points, closed } => {
                doubles(&mut coords, points.iter().flat_map(|p| [p.x, p.y]));
                (3, u32::from(*closed) << 8, coord_start, points.len() * 2)
            }
            Entity2DGeometry::Circle { center, radius } => {
                doubles(&mut coords, [center.x, center.y, *radius]);
                (4, 0, coord_start, 3)
            }
            Entity2DGeometry::Arc {
                center,
                radius,
                start_angle,
                end_angle,
            } => {
                doubles(
                    &mut coords,
                    [center.x, center.y, *radius, *start_angle, *end_angle],
                );
                (5, 0, coord_start, 5)
            }
            // Complete rich text, masks, SHX provenance, columns and future
            // nonnumeric geometry keep their exact existing JSON schema.
            Entity2DGeometry::Text(_) => {
                let start = fallback.len();
                serde_json::to_writer(&mut fallback, entity).map_err(|e| e.to_string())?;
                (0, 0, start, fallback.len() - start)
            }
        };
        records.extend_from_slice(&entity.id.to_le_bytes());
        records.extend_from_slice(&entity.layer_id.to_le_bytes());
        word(&mut records, style_id)?;
        records.extend_from_slice(&(kind | flags).to_le_bytes());
        word(&mut records, start)?;
        word(&mut records, length)?;
    }
    let mut style_records = Vec::with_capacity(styles.len() * STYLE_BYTES);
    for style in &styles {
        style_records.extend_from_slice(&style.color_argb.to_le_bytes());
        style_records.extend_from_slice(&u32::from(style.filled).to_le_bytes());
        doubles(&mut style_records, [style.stroke_width]);
        word(&mut style_records, dashes.len() / 8)?;
        word(&mut style_records, style.dash.len())?;
        doubles(&mut dashes, style.dash.iter().copied());
    }
    let metadata_end = 32usize
        .checked_add(metadata.len())
        .ok_or("packet overflow")?;
    let aligned = metadata_end.checked_add(7).ok_or("packet overflow")? & !7;
    let capacity = [
        records.len(),
        style_records.len(),
        coords.len(),
        dashes.len(),
        fallback.len(),
    ]
    .into_iter()
    .try_fold(aligned, |a, b| a.checked_add(b))
    .ok_or("packet overflow")?;
    // FRB's SSE byte-list codec uses a signed 32-bit length. Reject an
    // oversized viewport explicitly instead of truncating its wire length.
    if capacity > i32::MAX as usize {
        return Err("viewport packet exceeds bridge limits".to_owned());
    }
    let mut out = Vec::with_capacity(capacity);
    out.extend_from_slice(MAGIC);
    for value in [
        metadata.len(),
        entities.len(),
        coords.len() / 8,
        styles.len(),
        dashes.len() / 8,
        fallback.len(),
    ] {
        word(&mut out, value)?;
    }
    out.extend_from_slice(metadata.as_bytes());
    out.resize(aligned, 0);
    out.extend_from_slice(&records);
    out.extend_from_slice(&style_records);
    out.extend_from_slice(&coords);
    out.extend_from_slice(&dashes);
    out.extend_from_slice(&fallback);
    debug_assert_eq!(out.len(), capacity);
    Ok(out)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use cad_core::Point2;
    pub(crate) fn decode_3d(packet: &[u8]) -> serde_json::Value {
        use serde_json::{json, Value};
        assert_eq!(&packet[..8], b"CAD3D001");
        let word = |o| u32::from_le_bytes(packet[o..o + 4].try_into().unwrap()) as usize;
        let directory = (32 + word(8) + 7) & !7;
        let coordinates = (directory + word(12) * 12 + 7) & !7;
        let normals = coordinates + word(16) * 24;
        let indices = normals + word(20) * 12;
        let mut document: Value = serde_json::from_slice(&packet[32..32 + word(8)]).unwrap();
        let mut p = coordinates;
        let mut n = normals;
        let mut t = indices;
        for (i, mesh) in document["scene"]["scene"]["meshes"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .enumerate()
        {
            let position_count = word(directory + i * 12);
            let normal_count = word(directory + i * 12 + 4);
            let index_count = word(directory + i * 12 + 8);
            mesh["positions"] = Value::Array(
                (0..position_count)
                    .map(|_| {
                        let x = f64::from_le_bytes(packet[p..p + 8].try_into().unwrap());
                        let y = f64::from_le_bytes(packet[p + 8..p + 16].try_into().unwrap());
                        let z = f64::from_le_bytes(packet[p + 16..p + 24].try_into().unwrap());
                        p += 24;
                        json!({"x":x,"y":y,"z":z})
                    })
                    .collect(),
            );
            mesh["normals"] = Value::Array(
                (0..normal_count)
                    .map(|_| {
                        let values = (0..3)
                            .map(|_| {
                                let v = f32::from_le_bytes(packet[n..n + 4].try_into().unwrap());
                                n += 4;
                                v
                            })
                            .collect::<Vec<_>>();
                        json!(values)
                    })
                    .collect(),
            );
            mesh["indices"] = Value::Array(
                (0..index_count)
                    .map(|_| {
                        let v = u32::from_le_bytes(packet[t..t + 4].try_into().unwrap());
                        t += 4;
                        json!(v)
                    })
                    .collect(),
            );
        }
        assert_eq!(t, packet.len());
        document
    }

    #[test]
    fn mesh_packet_preserves_f64_normals_topology_and_optional_metadata() {
        use cad_core::Point3;
        let mut meshes = vec![
            Mesh3D {
                id: 42,
                name: "部件_日本語".to_owned(),
                positions: vec![
                    Point3::new(1e12 + 0.125, -0.0, 0.25),
                    Point3::new(1e12 + 1.125, 0.0, 0.5),
                    Point3::new(1e12 + 0.125, 1.0, 0.0),
                ],
                normals: vec![[0.25, -0.5, 1.0]; 3],
                indices: vec![2, 0, 1],
                material_index: Some(1),
                surface_area: Some(0.625),
                closed_manifold: Some(false),
                enclosed_volume: None,
                volume_centroid: Some(Point3::new(1e12 + 0.375, 0.25, 0.25)),
            },
            Mesh3D {
                id: 99,
                name: "empty".to_owned(),
                ..Default::default()
            },
        ];
        let metadata = serde_json::json!({"metadata":{"format":"obj"},"scene":{"scene_kind":"three_d","scene":{"meshes":[],"root_nodes":[],"materials":[],"stats":{}}},"diagnostics":[]}).to_string();
        let packet = encode_3d(&metadata, &meshes).unwrap();
        assert_eq!(
            decode_3d(&packet)["scene"]["scene"]["meshes"],
            serde_json::to_value(&meshes).unwrap()
        );
        // Odd directory length must also align f64 data, not only JSON.
        let single = encode_3d(&metadata, &meshes[..1]).unwrap();
        let metadata_len = u32::from_le_bytes(single[8..12].try_into().unwrap()) as usize;
        let position_start = (((32 + metadata_len + 7) & !7) + 12 + 7) & !7;
        assert_eq!(position_start % 8, 0);
        assert_eq!(
            &single[position_start + 8..position_start + 16],
            &(-0.0f64).to_le_bytes()
        );
        meshes[0].indices[0] = 3;
        assert!(encode_3d(&metadata, &meshes).is_err());
        meshes[0].indices = vec![0, 1];
        assert!(encode_3d(&metadata, &meshes).is_err());
    }
    // Independent reference decoder used by API/visibility parity tests.
    pub(crate) fn decode(packet: &[u8]) -> serde_json::Value {
        use serde_json::{json, Value};
        let u32_at = |o| u32::from_le_bytes(packet[o..o + 4].try_into().unwrap()) as usize;
        let u64_at = |o| u64::from_le_bytes(packet[o..o + 8].try_into().unwrap());
        let f64_at = |o| f64::from_le_bytes(packet[o..o + 8].try_into().unwrap());
        let records = (32 + u32_at(8) + 7) & !7;
        let styles = records + u32_at(12) * 32;
        let coordinates = styles + u32_at(20) * 24;
        let dashes = coordinates + u32_at(16) * 8;
        let fallback = dashes + u32_at(24) * 8;
        let mut document: Value = serde_json::from_slice(&packet[32..32 + u32_at(8)]).unwrap();
        let entities = (0..u32_at(12)).map(|i| {
            let record = records + i * 32;
            let kind = u32_at(record + 20) & 255;
            let first = u32_at(record + 24);
            let length = u32_at(record + 28);
            if kind == 0 {
                return serde_json::from_slice::<Value>(&packet[fallback + first..fallback + first + length]).unwrap();
            }
            let style = styles + u32_at(record + 16) * 24;
            let n = |i| f64_at(coordinates + (first + i) * 8);
            let p = |i| json!({"x":n(i), "y":n(i + 1)});
            let geometry = match kind {
                1 => json!({"kind":"point", "position":p(0)}),
                2 => json!({"kind":"line", "start":p(0), "end":p(2)}),
                3 => json!({"kind":"polyline", "closed":u32_at(record + 20) >> 8 == 1,
                    "points":(0..length).step_by(2).map(p).collect::<Vec<_>>() }),
                4 => json!({"kind":"circle", "center":p(0), "radius":n(2)}),
                5 => json!({"kind":"arc", "center":p(0), "radius":n(2), "start_angle":n(3), "end_angle":n(4)}),
                _ => panic!("unknown kind"),
            };
            let mut value = json!({"id":u64_at(record), "layer_id":u64_at(record + 8),
                "color_argb":u32_at(style), "stroke_width":f64_at(style + 8),
                "filled":u32_at(style + 4) == 1, "geometry":geometry});
            let dash_count = u32_at(style + 20);
            if dash_count != 0 {
                value["dash"] = json!((0..dash_count).map(|i| f64_at(dashes + (u32_at(style + 16) + i) * 8)).collect::<Vec<_>>());
            }
            value
        }).collect::<Vec<_>>();
        document["scene"]["scene"]["entities"] = json!(entities);
        document
    }
    #[test]
    fn million_lines_use_fixed_records_and_exact_f64_with_shared_styles() {
        let mut entity = Entity2D {
            id: 42,
            layer_id: 7,
            color_argb: 0xffaabbcc,
            stroke_width: 0.25,
            filled: false,
            dash: vec![3.0, -1.0],
            geometry: Entity2DGeometry::Line {
                start: Point2::new(1e12 + 0.125, -2.0),
                end: Point2::new(1e12 + 4.125, 0.0),
            },
        };
        let other = entity.clone();
        entity.id = 43;
        let packet = encode_2d("{}", &[&other, &entity]).unwrap();
        let u32_at = |offset| u32::from_le_bytes(packet[offset..offset + 4].try_into().unwrap());
        assert_eq!(&packet[..8], MAGIC);
        assert_eq!(u32_at(12), 2);
        assert_eq!(u32_at(16), 8);
        assert_eq!(u32_at(20), 1);
        assert_eq!(u32_at(24), 2);
        assert_eq!(packet.len(), 40 + 64 + 24 + 64 + 16);
        let coords_start = 40 + 64 + 24;
        assert_eq!(
            f64::from_le_bytes(packet[coords_start..coords_start + 8].try_into().unwrap()),
            1e12 + 0.125
        );
        // For continuous same-style lines the payload is 64 bytes/entity,
        // rather than one retained JSON map/point tree per source entity.
    }
}
