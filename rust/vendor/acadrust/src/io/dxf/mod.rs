//! DXF (Drawing Exchange Format) reading and writing.
//!
//! Supports both **ASCII** and **Binary** DXF for versions R12 (AC1009)
//! through R2018+ (AC1032).
//!
//! # Reading
//!
//! ```rust,ignore
//! use acadrust::DxfReader;
//!
//! let doc = DxfReader::from_file("drawing.dxf")?.read()?;
//! ```
//!
//! # Writing
//!
//! ```rust,ignore
//! use acadrust::DxfWriter;
//!
//! DxfWriter::new(&doc).write_to_file("output.dxf")?;
//! ```

pub mod code_page;
mod dxf_code;
mod group_code_value;
mod reader;
mod writer;

pub use dxf_code::DxfCode;
pub use group_code_value::GroupCodeValueType;
pub use reader::{DxfReader, DxfReaderConfiguration};
pub use writer::{value_type_for_code, write_binary_dxf, write_dxf};
pub use writer::{
    DxfBinaryWriter, DxfStreamWriter, DxfStreamWriterExt, DxfTextWriter, DxfWriter, SectionWriter,
};
