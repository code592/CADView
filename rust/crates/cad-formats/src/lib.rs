mod affine2d;
mod curves;
mod dwg_adapter;
mod dxf_adapter;
mod dxf_raw;
mod linetypes;
mod mesh_adapters;
mod mleader;
mod ocs_curves;
mod pending_adapters;
mod svg_adapter;
mod text_coordinates;
mod text_normalization;
mod units;

use cad_core::FormatRegistry;

pub use dwg_adapter::DwgAdapter;
pub use dxf_adapter::DxfAdapter;
pub use mesh_adapters::{GltfAdapter, ObjAdapter, StlAdapter, ThreeMfAdapter};
pub use pending_adapters::{IgesAdapter, PdfAdapter, StepAdapter};
pub use svg_adapter::SvgAdapter;

pub fn default_registry() -> FormatRegistry {
    let mut registry = FormatRegistry::default();
    registry.register(DxfAdapter);
    registry.register(SvgAdapter);
    registry.register(PdfAdapter);
    registry.register(ObjAdapter);
    registry.register(StlAdapter);
    registry.register(GltfAdapter);
    registry.register(ThreeMfAdapter);
    registry.register(DwgAdapter);
    registry.register(StepAdapter);
    registry.register(IgesAdapter);
    registry
}
#[cfg(test)]
mod dxf_dwg_parity_tests;
