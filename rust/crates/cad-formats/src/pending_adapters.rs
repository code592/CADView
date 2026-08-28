use cad_core::{
    fingerprint, CadError, CancellationToken, DocumentMetadata, FormatAdapter, FormatCapabilities,
    FormatId, OpenedDocument, PagedScene, SceneDocument, SceneKind, SceneSink, SupportLevel,
};
use std::path::Path;

pub struct PdfAdapter;
pub struct StepAdapter;
pub struct IgesAdapter;

impl FormatAdapter for PdfAdapter {
    fn capabilities(&self) -> FormatCapabilities {
        let mut result = capabilities(
            FormatId::Pdf,
            "Portable Document Format",
            &["pdf"],
            SceneKind::Paged,
            SupportLevel::Production,
            true,
            Some("Offline page rendering is provided by the pinned PDFium mobile runtime"),
        );
        result.can_measure = false;
        result
    }

    fn probe(&self, header: &[u8], path: Option<&Path>) -> u8 {
        if header.starts_with(b"%PDF-") {
            100
        } else {
            extension_score(path, &["pdf"], 30)
        }
    }

    fn open(
        &self,
        bytes: &[u8],
        display_name: &str,
        _source_path: Option<&Path>,
        cancel: &CancellationToken,
        mut sink: Option<&mut dyn SceneSink>,
    ) -> Result<OpenedDocument, CadError> {
        cancel.check()?;
        if !bytes.starts_with(b"%PDF-") {
            return Err(CadError::InvalidDocument("missing PDF header".to_owned()));
        }
        let page_count = count_pdf_pages(bytes).max(1);
        let document = OpenedDocument {
            metadata: metadata(FormatId::Pdf, display_name, bytes),
            scene: SceneDocument::Paged(PagedScene {
                page_count,
                current_page: 0,
                width_points: 612.0,
                height_points: 792.0,
            }),
            diagnostics: Vec::new(),
        };
        if let Some(sink) = sink.as_deref_mut() {
            sink.progress(1.0);
            sink.partial(&document);
        }
        Ok(document)
    }
}

macro_rules! unavailable_adapter {
    ($adapter:ident, $format:expr, $name:expr, $extensions:expr, $kind:expr, $level:expr, $signature:expr, $note:expr) => {
        impl FormatAdapter for $adapter {
            fn capabilities(&self) -> FormatCapabilities {
                capabilities(
                    $format,
                    $name,
                    $extensions,
                    $kind,
                    $level,
                    false,
                    Some($note),
                )
            }

            fn probe(&self, header: &[u8], path: Option<&Path>) -> u8 {
                if ($signature)(header) {
                    100
                } else {
                    extension_score(path, $extensions, 30)
                }
            }

            fn open(
                &self,
                _bytes: &[u8],
                _display_name: &str,
                _source_path: Option<&Path>,
                _cancel: &CancellationToken,
                _sink: Option<&mut dyn SceneSink>,
            ) -> Result<OpenedDocument, CadError> {
                Err(CadError::BackendUnavailable($format))
            }
        }
    };
}

unavailable_adapter!(
    StepAdapter,
    FormatId::Step,
    "STEP",
    &["step", "stp", "p21"],
    SceneKind::ThreeD,
    SupportLevel::Experimental,
    |header: &[u8]| String::from_utf8_lossy(header).contains("ISO-10303-21"),
    "Open CASCADE adapter is a separate phase-3 native module"
);

unavailable_adapter!(
    IgesAdapter,
    FormatId::Iges,
    "IGES",
    &["iges", "igs"],
    SceneKind::ThreeD,
    SupportLevel::Experimental,
    |_header: &[u8]| false,
    "Open CASCADE adapter is a separate phase-3 native module"
);

fn capabilities(
    format: FormatId,
    display_name: &str,
    extensions: &[&str],
    scene_kind: SceneKind,
    support_level: SupportLevel,
    available: bool,
    note: Option<&str>,
) -> FormatCapabilities {
    FormatCapabilities {
        format,
        display_name: display_name.to_owned(),
        extensions: extensions.iter().map(|value| (*value).to_owned()).collect(),
        scene_kind,
        support_level,
        available,
        can_stream: false,
        can_measure: available,
        can_select_topology: false,
        note: note.map(str::to_owned),
    }
}

fn metadata(format: FormatId, display_name: &str, bytes: &[u8]) -> DocumentMetadata {
    DocumentMetadata {
        format,
        display_name: display_name.to_owned(),
        fingerprint: fingerprint(bytes),
        byte_length: bytes.len() as u64,
        units: None,
        author: None,
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

fn count_pdf_pages(bytes: &[u8]) -> u32 {
    bytes
        .windows(b"/Type /Page".len())
        .filter(|window| *window == b"/Type /Page")
        .count()
        .min(u32::MAX as usize) as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_pdf_by_magic_not_extension() {
        assert_eq!(PdfAdapter.probe(b"%PDF-1.7\n", None), 100);
    }
}
