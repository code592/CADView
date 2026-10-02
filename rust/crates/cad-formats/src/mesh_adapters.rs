use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use cad_core::{
    fingerprint, mesh_surface_area, mesh_volume_properties, AssemblyNode, CadError,
    CancellationToken, DocumentMetadata, FormatAdapter, FormatCapabilities, FormatDiagnostic,
    FormatId, Mesh3D, OpenedDocument, Point3, Scene3D, SceneDocument, SceneKind, SceneSink,
    SupportLevel,
};
use gltf::buffer::Source as BufferSource;
use std::{
    io::{Cursor, Read},
    path::Path,
};

pub struct ObjAdapter;
pub struct StlAdapter;
pub struct GltfAdapter;
pub struct ThreeMfAdapter;

impl FormatAdapter for ObjAdapter {
    fn capabilities(&self) -> FormatCapabilities {
        mesh_capabilities(
            FormatId::Obj,
            "Wavefront OBJ",
            &["obj"],
            SupportLevel::Production,
        )
    }

    fn probe(&self, header: &[u8], path: Option<&Path>) -> u8 {
        let text = String::from_utf8_lossy(header);
        if text.lines().any(|line| line.starts_with("v "))
            && text.lines().any(|line| line.starts_with("f "))
        {
            90
        } else {
            extension_score(path, &["obj"], 35)
        }
    }

    fn open(
        &self,
        bytes: &[u8],
        display_name: &str,
        source_path: Option<&Path>,
        cancel: &CancellationToken,
        sink: Option<&mut dyn SceneSink>,
    ) -> Result<OpenedDocument, CadError> {
        cancel.check()?;
        let mut reader = Cursor::new(bytes);
        let (models, _materials) = tobj::load_obj_buf(
            &mut reader,
            &tobj::LoadOptions {
                triangulate: true,
                single_index: true,
                ..Default::default()
            },
            |material_path| {
                source_path
                    .and_then(Path::parent)
                    .map(|parent| parent.join(material_path))
                    .map(tobj::load_mtl)
                    .unwrap_or_else(|| Ok((Vec::new(), Default::default())))
            },
        )
        .map_err(|error| CadError::InvalidDocument(format!("OBJ parse failed: {error}")))?;

        let meshes = models
            .into_iter()
            .enumerate()
            .map(|(index, model)| {
                let positions = model
                    .mesh
                    .positions
                    .chunks_exact(3)
                    .map(|p| Point3::new(p[0] as f64, p[1] as f64, p[2] as f64))
                    .collect();
                let normals = model
                    .mesh
                    .normals
                    .chunks_exact(3)
                    .map(|n| [n[0], n[1], n[2]])
                    .collect();
                Mesh3D {
                    id: index as u64 + 1,
                    name: if model.name.is_empty() {
                        format!("Mesh {}", index + 1)
                    } else {
                        model.name
                    },
                    positions,
                    normals,
                    indices: model.mesh.indices,
                    material_index: model.mesh.material_id.map(|value| value as u32),
                    surface_area: None,
                    closed_manifold: None,
                    enclosed_volume: None,
                    volume_centroid: None,
                }
            })
            .collect();
        finish_mesh_document(
            FormatId::Obj,
            display_name,
            bytes,
            meshes,
            Vec::new(),
            None,
            sink,
        )
    }
}

impl FormatAdapter for StlAdapter {
    fn capabilities(&self) -> FormatCapabilities {
        mesh_capabilities(
            FormatId::Stl,
            "Stereolithography",
            &["stl"],
            SupportLevel::Production,
        )
    }

    fn probe(&self, header: &[u8], path: Option<&Path>) -> u8 {
        if header.starts_with(b"solid ") {
            80
        } else {
            extension_score(path, &["stl"], 45)
        }
    }

    fn open(
        &self,
        bytes: &[u8],
        display_name: &str,
        _source_path: Option<&Path>,
        cancel: &CancellationToken,
        sink: Option<&mut dyn SceneSink>,
    ) -> Result<OpenedDocument, CadError> {
        cancel.check()?;
        let indexed = stl_io::read_stl(&mut Cursor::new(bytes))
            .map_err(|error| CadError::InvalidDocument(format!("STL parse failed: {error}")))?;
        let mesh = Mesh3D {
            id: 1,
            name: display_name.to_owned(),
            positions: indexed
                .vertices
                .iter()
                .map(|p| Point3::new(p[0] as f64, p[1] as f64, p[2] as f64))
                .collect(),
            normals: Vec::new(),
            indices: indexed
                .faces
                .iter()
                .flat_map(|face| face.vertices)
                .map(|value| value as u32)
                .collect(),
            material_index: None,
            surface_area: None,
            closed_manifold: None,
            enclosed_volume: None,
            volume_centroid: None,
        };
        finish_mesh_document(
            FormatId::Stl,
            display_name,
            bytes,
            vec![mesh],
            Vec::new(),
            None,
            sink,
        )
    }
}

impl FormatAdapter for GltfAdapter {
    fn capabilities(&self) -> FormatCapabilities {
        let mut capabilities = mesh_capabilities(
            FormatId::Gltf,
            "glTF 2.0",
            &["gltf", "glb"],
            SupportLevel::Production,
        );
        capabilities.note =
            Some("Embedded GLB/data buffers and sibling .bin buffers are supported".to_owned());
        capabilities
    }

    fn probe(&self, header: &[u8], path: Option<&Path>) -> u8 {
        if header.starts_with(b"glTF") {
            return 100;
        }
        let text = String::from_utf8_lossy(header);
        if text.contains("\"asset\"") && text.contains("\"version\"") {
            90
        } else {
            extension_score(path, &["gltf", "glb"], 35)
        }
    }

    fn open(
        &self,
        bytes: &[u8],
        display_name: &str,
        source_path: Option<&Path>,
        cancel: &CancellationToken,
        sink: Option<&mut dyn SceneSink>,
    ) -> Result<OpenedDocument, CadError> {
        cancel.check()?;
        let gltf = gltf::Gltf::from_slice(bytes)
            .map_err(|error| CadError::InvalidDocument(format!("glTF parse failed: {error}")))?;
        let buffers = load_gltf_buffers(&gltf, source_path)?;
        let mut meshes = Vec::new();
        for source_mesh in gltf.meshes() {
            for (primitive_index, primitive) in source_mesh.primitives().enumerate() {
                cancel.check()?;
                let reader =
                    primitive.reader(|buffer| buffers.get(buffer.index()).map(Vec::as_slice));
                let Some(positions) = reader.read_positions() else {
                    continue;
                };
                let positions = positions
                    .map(|p| Point3::new(p[0] as f64, p[1] as f64, p[2] as f64))
                    .collect::<Vec<_>>();
                let normals = reader
                    .read_normals()
                    .map(|values| values.collect())
                    .unwrap_or_default();
                let indices = reader
                    .read_indices()
                    .map(|values| values.into_u32().collect())
                    .unwrap_or_else(|| (0..positions.len() as u32).collect());
                let id = meshes.len() as u64 + 1;
                meshes.push(Mesh3D {
                    id,
                    name: format!(
                        "{} {}",
                        source_mesh.name().unwrap_or("Mesh"),
                        primitive_index + 1
                    ),
                    positions,
                    normals,
                    indices,
                    material_index: primitive.material().index().map(|value| value as u32),
                    surface_area: None,
                    closed_manifold: None,
                    enclosed_volume: None,
                    volume_centroid: None,
                });
            }
        }
        finish_mesh_document(
            FormatId::Gltf,
            display_name,
            bytes,
            meshes,
            Vec::new(),
            Some("m"),
            sink,
        )
    }
}

impl FormatAdapter for ThreeMfAdapter {
    fn capabilities(&self) -> FormatCapabilities {
        mesh_capabilities(
            FormatId::ThreeMf,
            "3D Manufacturing Format",
            &["3mf"],
            SupportLevel::Beta,
        )
    }

    fn probe(&self, header: &[u8], path: Option<&Path>) -> u8 {
        if header.starts_with(b"PK\x03\x04") {
            extension_score(path, &["3mf"], 90)
        } else {
            extension_score(path, &["3mf"], 35)
        }
    }

    fn open(
        &self,
        bytes: &[u8],
        display_name: &str,
        _source_path: Option<&Path>,
        cancel: &CancellationToken,
        sink: Option<&mut dyn SceneSink>,
    ) -> Result<OpenedDocument, CadError> {
        cancel.check()?;
        let mut archive = zip::ZipArchive::new(Cursor::new(bytes))
            .map_err(|error| CadError::InvalidDocument(format!("3MF ZIP failed: {error}")))?;
        const MAX_ARCHIVE_ENTRIES: usize = 10_000;
        const MAX_EXPANDED_BYTES: u64 = 1024 * 1024 * 1024;
        if archive.len() > MAX_ARCHIVE_ENTRIES {
            return Err(CadError::ResourceLimit(
                "3MF archive has more than 10,000 entries".to_owned(),
            ));
        }
        let mut expanded_bytes = 0_u64;
        for index in 0..archive.len() {
            expanded_bytes = expanded_bytes.saturating_add(
                archive
                    .by_index(index)
                    .map_err(|error| CadError::InvalidDocument(error.to_string()))?
                    .size(),
            );
            if expanded_bytes > MAX_EXPANDED_BYTES {
                return Err(CadError::ResourceLimit(
                    "expanded 3MF archive exceeds 1 GiB".to_owned(),
                ));
            }
        }
        let model_name = archive
            .file_names()
            .find(|name| name.to_ascii_lowercase().ends_with(".model"))
            .map(str::to_owned)
            .ok_or_else(|| CadError::InvalidDocument("3MF has no .model part".to_owned()))?;
        let mut xml = String::new();
        archive
            .by_name(&model_name)
            .map_err(|error| CadError::InvalidDocument(format!("3MF model part failed: {error}")))?
            .read_to_string(&mut xml)
            .map_err(CadError::Io)?;
        let document = roxmltree::Document::parse(&xml)
            .map_err(|error| CadError::InvalidDocument(format!("3MF XML failed: {error}")))?;
        let unit_id = three_mf_unit_id(document.root_element().attribute("unit"));
        let mut meshes = Vec::new();
        for object in document
            .descendants()
            .filter(|node| node.tag_name().name() == "object")
        {
            let Some(mesh_node) = object
                .children()
                .find(|node| node.tag_name().name() == "mesh")
            else {
                continue;
            };
            let positions = mesh_node
                .descendants()
                .filter(|node| node.tag_name().name() == "vertex")
                .filter_map(|node| {
                    Some(Point3::new(
                        node.attribute("x")?.parse().ok()?,
                        node.attribute("y")?.parse().ok()?,
                        node.attribute("z")?.parse().ok()?,
                    ))
                })
                .collect::<Vec<_>>();
            let indices = mesh_node
                .descendants()
                .filter(|node| node.tag_name().name() == "triangle")
                .flat_map(|node| {
                    ["v1", "v2", "v3"]
                        .into_iter()
                        .filter_map(move |name| node.attribute(name)?.parse::<u32>().ok())
                })
                .collect::<Vec<_>>();
            if positions.len() > 10_000_000 || indices.len() > 30_000_000 {
                return Err(CadError::ResourceLimit(
                    "3MF mesh exceeds vertex or triangle limits".to_owned(),
                ));
            }
            if !positions.is_empty() && !indices.is_empty() {
                meshes.push(Mesh3D {
                    id: object
                        .attribute("id")
                        .and_then(|value| value.parse().ok())
                        .unwrap_or(meshes.len() as u64 + 1),
                    name: object.attribute("name").unwrap_or("3MF object").to_owned(),
                    positions,
                    normals: Vec::new(),
                    indices,
                    material_index: None,
                    surface_area: None,
                    closed_manifold: None,
                    enclosed_volume: None,
                    volume_centroid: None,
                });
            }
        }
        finish_mesh_document(
            FormatId::ThreeMf,
            display_name,
            bytes,
            meshes,
            Vec::new(),
            unit_id,
            sink,
        )
    }
}

fn load_gltf_buffers(
    gltf: &gltf::Gltf,
    source_path: Option<&Path>,
) -> Result<Vec<Vec<u8>>, CadError> {
    let buffers =
        gltf.buffers()
            .map(|buffer| match buffer.source() {
                BufferSource::Bin => gltf.blob.clone().ok_or_else(|| {
                    CadError::InvalidDocument("GLB binary buffer is missing".to_owned())
                }),
                BufferSource::Uri(uri) if uri.starts_with("data:") => {
                    let encoded = uri.split_once(',').map(|(_, value)| value).ok_or_else(|| {
                        CadError::InvalidDocument("invalid glTF data URI".to_owned())
                    })?;
                    BASE64.decode(encoded).map_err(|error| {
                        CadError::InvalidDocument(format!("invalid glTF base64 buffer: {error}"))
                    })
                }
                BufferSource::Uri(uri) => {
                    let parent = source_path.and_then(Path::parent).ok_or_else(|| {
                        CadError::InvalidDocument(format!(
                            "external glTF buffer cannot be resolved: {uri}"
                        ))
                    })?;
                    std::fs::read(parent.join(uri)).map_err(CadError::Io)
                }
            })
            .collect::<Result<Vec<_>, _>>()?;
    const MAX_BUFFER_BYTES: usize = 1024 * 1024 * 1024;
    if buffers
        .iter()
        .map(Vec::len)
        .try_fold(0_usize, usize::checked_add)
        .is_none_or(|length| length > MAX_BUFFER_BYTES)
    {
        return Err(CadError::ResourceLimit(
            "glTF buffers exceed 1 GiB".to_owned(),
        ));
    }
    Ok(buffers)
}

fn three_mf_unit_id(value: Option<&str>) -> Option<&'static str> {
    match value.unwrap_or("millimeter") {
        "micron" => Some("micron"),
        "millimeter" => Some("mm"),
        "centimeter" => Some("cm"),
        "inch" => Some("in"),
        "foot" => Some("ft"),
        "meter" => Some("m"),
        _ => None,
    }
}

fn finish_mesh_document(
    format: FormatId,
    display_name: &str,
    bytes: &[u8],
    mut meshes: Vec<Mesh3D>,
    diagnostics: Vec<FormatDiagnostic>,
    units: Option<&str>,
    mut sink: Option<&mut dyn SceneSink>,
) -> Result<OpenedDocument, CadError> {
    if meshes.is_empty() {
        return Err(CadError::InvalidDocument(
            "document contains no renderable mesh".to_owned(),
        ));
    }
    for mesh in &mut meshes {
        mesh.surface_area = mesh_surface_area(&mesh.positions, &mesh.indices);
        if let Some(properties) = mesh_volume_properties(&mesh.positions, &mesh.indices) {
            mesh.closed_manifold = Some(properties.closed_manifold);
            mesh.enclosed_volume = properties.enclosed_volume;
            mesh.volume_centroid = properties.volume_centroid;
        }
    }
    let children = meshes
        .iter()
        .map(|mesh| AssemblyNode {
            id: mesh.id,
            name: mesh.name.clone(),
            visible: true,
            mesh_ids: vec![mesh.id],
            children: Vec::new(),
        })
        .collect();
    let mut scene = Scene3D {
        root_nodes: vec![AssemblyNode {
            id: 0,
            name: display_name.to_owned(),
            visible: true,
            mesh_ids: Vec::new(),
            children,
        }],
        meshes,
        materials: Vec::new(),
        bounds: None,
        stats: Default::default(),
    };
    scene.recompute_stats();
    let document = OpenedDocument {
        metadata: DocumentMetadata {
            format,
            display_name: display_name.to_owned(),
            fingerprint: fingerprint(bytes),
            byte_length: bytes.len() as u64,
            units: units.map(str::to_owned),
            author: None,
        },
        scene: SceneDocument::ThreeD(scene),
        diagnostics,
    };
    if let Some(sink) = sink.as_deref_mut() {
        sink.progress(1.0);
        sink.partial(&document);
    }
    Ok(document)
}

fn mesh_capabilities(
    format: FormatId,
    name: &str,
    extensions: &[&str],
    level: SupportLevel,
) -> FormatCapabilities {
    FormatCapabilities {
        format,
        display_name: name.to_owned(),
        extensions: extensions.iter().map(|value| (*value).to_owned()).collect(),
        scene_kind: SceneKind::ThreeD,
        support_level: level,
        available: true,
        can_stream: false,
        can_measure: true,
        can_select_topology: false,
        note: None,
    }
}

fn extension_score(path: Option<&Path>, extensions: &[&str], score: u8) -> u8 {
    path.and_then(Path::extension)
        .and_then(|value| value.to_str())
        .filter(|value| {
            extensions
                .iter()
                .any(|extension| value.eq_ignore_ascii_case(extension))
        })
        .map_or(0, |_| score)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opens_obj_mesh() {
        let bytes = b"o triangle\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n";
        let opened = ObjAdapter
            .open(
                bytes,
                "triangle.obj",
                None,
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        match opened.scene {
            SceneDocument::ThreeD(scene) => {
                assert_eq!(scene.stats.vertex_count, 3);
                assert_eq!(scene.stats.triangle_count, 1);
                assert_eq!(scene.meshes[0].surface_area, Some(0.5));
                assert_eq!(scene.meshes[0].closed_manifold, Some(false));
                assert_eq!(scene.meshes[0].enclosed_volume, None);
                assert_eq!(scene.meshes[0].volume_centroid, None);
            }
            _ => panic!("expected a 3D scene"),
        }
    }

    #[test]
    fn maps_3mf_declared_units_and_spec_default() {
        assert_eq!(three_mf_unit_id(None), Some("mm"));
        assert_eq!(three_mf_unit_id(Some("micron")), Some("micron"));
        assert_eq!(three_mf_unit_id(Some("centimeter")), Some("cm"));
        assert_eq!(three_mf_unit_id(Some("inch")), Some("in"));
        assert_eq!(three_mf_unit_id(Some("foot")), Some("ft"));
        assert_eq!(three_mf_unit_id(Some("meter")), Some("m"));
        assert_eq!(three_mf_unit_id(Some("unsupported")), None);
    }
}
