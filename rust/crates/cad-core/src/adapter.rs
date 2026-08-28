use crate::{DocumentMetadata, FormatCapabilities, FormatId, OpenedDocument};
use std::{
    io::Read,
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum CadError {
    #[error("unsupported format: {0}")]
    UnsupportedFormat(String),
    #[error("format backend is not available: {0:?}")]
    BackendUnavailable(FormatId),
    #[error("document was cancelled")]
    Cancelled,
    #[error("invalid document: {0}")]
    InvalidDocument(String),
    #[error("resource limit exceeded: {0}")]
    ResourceLimit(String),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Clone, Default)]
pub struct CancellationToken(Arc<AtomicBool>);

impl CancellationToken {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
    pub fn check(&self) -> Result<(), CadError> {
        if self.is_cancelled() {
            Err(CadError::Cancelled)
        } else {
            Ok(())
        }
    }
}

pub trait SceneSink {
    fn progress(&mut self, fraction: f32);
    fn partial(&mut self, document: &OpenedDocument);
}

pub trait FormatAdapter: Send + Sync {
    fn capabilities(&self) -> FormatCapabilities;
    fn probe(&self, header: &[u8], path_hint: Option<&Path>) -> u8;
    fn open(
        &self,
        bytes: &[u8],
        display_name: &str,
        source_path: Option<&Path>,
        cancel: &CancellationToken,
        sink: Option<&mut dyn SceneSink>,
    ) -> Result<OpenedDocument, CadError>;

    fn open_path(
        &self,
        path: &Path,
        display_name: &str,
        cancel: &CancellationToken,
        sink: Option<&mut dyn SceneSink>,
    ) -> Result<OpenedDocument, CadError> {
        let bytes = std::fs::read(path)?;
        cancel.check()?;
        self.open(&bytes, display_name, Some(path), cancel, sink)
    }

    fn stream_scene(
        &self,
        bytes: &[u8],
        display_name: &str,
        source_path: Option<&Path>,
        cancel: &CancellationToken,
        sink: &mut dyn SceneSink,
    ) -> Result<OpenedDocument, CadError> {
        self.open(bytes, display_name, source_path, cancel, Some(sink))
    }

    fn metadata(
        &self,
        bytes: &[u8],
        display_name: &str,
        source_path: Option<&Path>,
        cancel: &CancellationToken,
    ) -> Result<DocumentMetadata, CadError> {
        self.open(bytes, display_name, source_path, cancel, None)
            .map(|document| document.metadata)
    }

    fn cancel(&self, token: &CancellationToken) {
        token.cancel();
    }
}

#[derive(Default)]
pub struct FormatRegistry {
    adapters: Vec<Arc<dyn FormatAdapter>>,
}

impl FormatRegistry {
    pub fn register<A: FormatAdapter + 'static>(&mut self, adapter: A) {
        self.adapters.push(Arc::new(adapter));
    }

    pub fn capabilities(&self) -> Vec<FormatCapabilities> {
        self.adapters
            .iter()
            .map(|adapter| adapter.capabilities())
            .collect()
    }

    pub fn detect(&self, bytes: &[u8], path: Option<&Path>) -> Option<Arc<dyn FormatAdapter>> {
        let header = &bytes[..bytes.len().min(4096)];
        self.adapters
            .iter()
            .map(|adapter| (adapter.probe(header, path), Arc::clone(adapter)))
            .max_by_key(|(score, _)| *score)
            .and_then(|(score, adapter)| (score > 0).then_some(adapter))
    }

    pub fn open_path(
        &self,
        path: &Path,
        cancel: &CancellationToken,
        sink: Option<&mut dyn SceneSink>,
    ) -> Result<OpenedDocument, CadError> {
        const MAX_SOURCE_BYTES: u64 = 2 * 1024 * 1024 * 1024;
        let byte_length = std::fs::metadata(path)?.len();
        if byte_length > MAX_SOURCE_BYTES {
            return Err(CadError::ResourceLimit(format!(
                "source is {byte_length} bytes; limit is {MAX_SOURCE_BYTES}"
            )));
        }
        let mut file = std::fs::File::open(path)?;
        let mut header = vec![0_u8; byte_length.min(4096) as usize];
        file.read_exact(&mut header)?;
        cancel.check()?;
        let adapter = self.detect(&header, Some(path)).ok_or_else(|| {
            CadError::UnsupportedFormat(
                path.extension()
                    .and_then(|value| value.to_str())
                    .unwrap_or("unknown")
                    .to_owned(),
            )
        })?;
        adapter.open_path(
            path,
            path.file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("Untitled"),
            cancel,
            sink,
        )
    }
}
