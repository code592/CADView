//! Format-independent CAD domain model.
//!
//! This crate deliberately has no Flutter, GPU, database, or parser dependency.

pub mod adapter;
pub mod annotation;
pub mod measurement;
pub mod scene;
pub mod spatial;
pub mod types;

pub use adapter::*;
pub use annotation::*;
pub use measurement::*;
pub use scene::*;
pub use spatial::*;
pub use types::*;
